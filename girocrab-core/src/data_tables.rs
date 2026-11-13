//! Reference tables embedded from `girocrab-core/data/*.tsv` (BIC and FinTS
//! directories, merchant dictionary).
//!
//! The tables are plain text instead of Rust literals: diffs stay readable and
//! rustc does not type-check thousands of tuples on every build. They are
//! embedded with `include_str!` and parsed once on first use; the parsed
//! fields borrow from the embedded text, so lookups stay `&'static str`
//! without copying.

/// Data rows of a tab-separated table. Blank lines and lines starting with `#`
/// are skipped. Missing trailing columns read as `""` (editors may strip
/// trailing tabs); a row with more than `N` columns is dropped, which
/// [`malformed_rows`] reports in tests.
pub(crate) fn rows<const N: usize>(text: &'static str) -> impl Iterator<Item = [&'static str; N]> {
    data_lines(text).filter_map(|line| {
        let mut cols = line.split('\t');
        let row = std::array::from_fn(|_| cols.next().unwrap_or(""));
        cols.next().is_none().then_some(row)
    })
}

fn data_lines(text: &str) -> impl Iterator<Item = &str> {
    text.lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
}

/// Data lines with fewer than `min` or more than `max` columns.
#[cfg(test)]
pub(crate) fn malformed_rows(text: &str, min: usize, max: usize) -> Vec<&str> {
    data_lines(text)
        .filter(|l| !(min..=max).contains(&l.split('\t').count()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_comments_and_pads_missing_columns() {
        let text = "# header\n\na\tb\tc\n\nd\te\n# x\tf\n";
        let got: Vec<[&str; 3]> = rows(text).collect();
        assert_eq!(got, [["a", "b", "c"], ["d", "e", ""]]);
        assert!(malformed_rows(text, 2, 3).is_empty());
        assert_eq!(rows::<2>("a\tb\tc\n").count(), 0);
        assert_eq!(malformed_rows("a\tb\tc\nd\n", 2, 2), ["a\tb\tc", "d"]);
    }
}
