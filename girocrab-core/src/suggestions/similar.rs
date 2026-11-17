//! Stage 3 (#664): bookings with similar text, for a merchant without history. Counterparty, purpose and
//! booking text become a set of words; a word counts the more, the rarer it is
//! in the history (tf-idf with binary term frequency), and two bookings are as
//! similar as the cosine of their word weights. Numbers, short words and bank
//! wording carry no meaning about the payee and are left out, and so is any
//! word on more than [`MAX_DOC_SHARE`] of the history and on more than
//! [`MIN_DOC_LIMIT`] bookings (the user's own name, "Abrechnung", …).

use std::collections::HashMap;

use super::Vote;

/// Share of the history above which a word says nothing …
const MAX_DOC_SHARE: f64 = 0.02;
/// … unless it is on no more bookings than this (a small history).
const MIN_DOC_LIMIT: u32 = 25;

/// Words about the payment, not the payee.
const STOP_WORDS: &[&str] = &[
    "abwa",
    "basislastschrift",
    "bei",
    "bic",
    "cred",
    "danke",
    "das",
    "datum",
    "debitk",
    "der",
    "die",
    "einkauf",
    "einzug",
    "end",
    "eref",
    "firmenlastschrift",
    "folgenr",
    "für",
    "fuer",
    "girocard",
    "gutschrift",
    "iban",
    "ihr",
    "ihre",
    "kartenzahlung",
    "kref",
    "kundennr",
    "lastschrift",
    "mandat",
    "mastercard",
    "mit",
    "mref",
    "online",
    "per",
    "ref",
    "referenz",
    "sagt",
    "sepa",
    "svwz",
    "ueberweisung",
    "uhr",
    "und",
    "verfalld",
    "visa",
    "vom",
    "von",
    "www",
    "zahlung",
    "zum",
    "zur",
    "überweisung",
    "dauerauftrag",
    "gmbh",
    "mbh",
    "the",
    "com",
];

/// The distinct meaningful words of some texts, lower case.
pub(super) fn words(texts: &[&str]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for text in texts {
        for w in text.to_lowercase().split(|c: char| !c.is_alphanumeric()) {
            if w.chars().count() < 3
                || w.chars().any(|c| c.is_ascii_digit())
                || STOP_WORDS.contains(&w)
                || out.iter().any(|o| o == w)
            {
                continue;
            }
            out.push(w.to_string());
        }
    }
    out
}

struct Doc {
    vote: Vote,
    income: bool,
    norm: f64,
}

/// Inverted index of the history's words.
#[derive(Default)]
pub(super) struct TextIndex {
    idf: HashMap<String, f64>,
    postings: HashMap<String, Vec<u32>>,
    docs: Vec<Doc>,
}

impl TextIndex {
    /// `entries`: each history booking's vote, direction and words.
    pub(super) fn build(entries: Vec<(Vote, bool, Vec<String>)>) -> Self {
        let n = entries.len().max(1) as f64;
        let mut df: HashMap<&str, u32> = HashMap::new();
        for (_, _, words) in &entries {
            for w in words {
                *df.entry(w.as_str()).or_default() += 1;
            }
        }
        let idf: HashMap<String, f64> = df
            .into_iter()
            .filter(|(_, d)| *d <= MIN_DOC_LIMIT || f64::from(*d) / n <= MAX_DOC_SHARE)
            .map(|(w, d)| (w.to_string(), (n / f64::from(d)).ln()))
            .collect();
        let mut index = TextIndex {
            idf,
            ..Default::default()
        };
        for (vote, income, words) in entries {
            let kept: Vec<(&String, f64)> = words
                .iter()
                .filter_map(|w| index.idf.get(w).map(|&i| (w, i)))
                .collect();
            let norm = kept.iter().map(|(_, i)| i * i).sum::<f64>().sqrt();
            if norm == 0.0 {
                continue;
            }
            let id = index.docs.len() as u32;
            for (w, _) in kept {
                index.postings.entry(w.clone()).or_default().push(id);
            }
            index.docs.push(Doc { vote, income, norm });
        }
        index
    }

    /// Up to `k` history bookings in the same direction with a similarity of at
    /// least `min_similarity` to `query`, most similar first; `keep` decides
    /// which votes may count.
    pub(super) fn nearest(
        &self,
        query: &[String],
        income: bool,
        k: usize,
        min_similarity: f64,
        keep: impl Fn(&Vote) -> bool,
    ) -> Vec<(&Vote, f64)> {
        let weights: Vec<(&String, f64)> = query
            .iter()
            .filter_map(|w| self.idf.get(w).map(|&i| (w, i)))
            .collect();
        let qnorm = weights.iter().map(|(_, i)| i * i).sum::<f64>().sqrt();
        if k == 0 || qnorm == 0.0 {
            return Vec::new();
        }
        let mut dot: HashMap<u32, f64> = HashMap::new();
        for (w, i) in &weights {
            for &d in self.postings.get(*w).into_iter().flatten() {
                if self.docs[d as usize].income == income {
                    *dot.entry(d).or_default() += i * i;
                }
            }
        }
        let mut hits: Vec<(&Vote, f64)> = dot
            .into_iter()
            .map(|(d, s)| {
                let doc = &self.docs[d as usize];
                (&doc.vote, s / (qnorm * doc.norm))
            })
            .filter(|(v, sim)| *sim >= min_similarity && keep(v))
            .collect();
        hits.sort_by(|a, b| {
            b.1.total_cmp(&a.1)
                .then(a.0.booking_id.cmp(&b.0.booking_id))
        });
        hits.truncate(k);
        hits
    }
}
