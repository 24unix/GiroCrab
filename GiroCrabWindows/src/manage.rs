//! Pure logic of the Windows front end for account / category management and the keyboard
//! shortcuts: form validation, the two-click delete gate and the routing of key presses to
//! commands. No Slint and no vault access here, so everything is unit-tested on every platform.

/// A dialog laid over the main window (see `main.slint`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Modal {
    Tan,
    Transfer,
    AddBank,
    Account,
    Categories,
    About,
}

/// Which dialogs are open right now.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modals {
    pub tan: bool,
    pub transfer: bool,
    pub add_bank: bool,
    pub account: bool,
    pub categories: bool,
    pub about: bool,
}

impl Modals {
    /// The dialog on top: a PIN / TAN prompt covers a transfer, which covers the rest.
    pub fn top(&self) -> Option<Modal> {
        [
            (self.tan, Modal::Tan),
            (self.transfer, Modal::Transfer),
            (self.add_bank, Modal::AddBank),
            (self.account, Modal::Account),
            (self.categories, Modal::Categories),
            (self.about, Modal::About),
        ]
        .into_iter()
        .find_map(|(open, m)| open.then_some(m))
    }
}

/// What a shortcut asks the window to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    FocusSearch,
    Lock,
    Refresh,
    Import,
    NewTransfer,
    CloseModal(Modal),
}

/// State a shortcut depends on.
#[derive(Debug, Clone, Copy, Default)]
pub struct Context {
    pub unlocked: bool,
    pub busy: bool,
    pub can_transfer: bool,
    pub modals: Modals,
}

const KEY_ESCAPE: char = '\u{1b}';
/// Slint's `Key.F5`.
const KEY_F5: char = '\u{f708}';

/// Maps the text of a Slint key event to the key it stands for: letters in lower case (some
/// backends report Ctrl+F as the control character U+0006), `Esc` and `F5` as such.
fn normalize(text: &str) -> Option<char> {
    let mut chars = text.chars();
    let c = chars.next().filter(|_| chars.next().is_none())?;
    match c {
        KEY_ESCAPE | KEY_F5 => Some(c),
        '\u{1}'..='\u{1a}' => Some((b'a' + c as u8 - 1) as char),
        c => Some(c.to_ascii_lowercase()),
    }
}

/// Routes a key press: Esc closes the top dialog; with a dialog open, nothing else fires.
/// `Ctrl+F` search, `Ctrl+L` lock, `Ctrl+R` / `F5` refresh, `Ctrl+I` import, `Ctrl+N` transfer.
pub fn route(text: &str, ctrl: bool, ctx: &Context) -> Option<Command> {
    if !ctx.unlocked {
        return None;
    }
    let key = normalize(text)?;
    if key == KEY_ESCAPE {
        return ctx.modals.top().map(Command::CloseModal);
    }
    if ctx.modals.top().is_some() {
        return None;
    }
    match (key, ctrl) {
        ('f', true) => Some(Command::FocusSearch),
        ('l', true) => Some(Command::Lock),
        ('r', true) | (KEY_F5, _) if !ctx.busy => Some(Command::Refresh),
        ('i', true) if !ctx.busy => Some(Command::Import),
        ('n', true) if !ctx.busy && ctx.can_transfer => Some(Command::NewTransfer),
        _ => None,
    }
}

/// `#RRGGBB` (upper case) from user or palette input; `None` if it is not a six-digit hex colour.
pub fn normalize_color(input: &str) -> Option<String> {
    let hex = input.trim().strip_prefix('#')?;
    (hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()))
        .then(|| format!("#{}", hex.to_ascii_uppercase()))
}

/// Position of `hex` in the palette (case-insensitive); `None` = a colour outside the palette.
pub fn palette_index(palette: &[String], hex: &str) -> Option<usize> {
    palette.iter().position(|p| p.eq_ignore_ascii_case(hex))
}

/// A name the vault accepts: trimmed, not empty, one line, at most 80 characters.
pub fn validate_name(what: &str, name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(format!("Bitte einen Namen für {what} eingeben."));
    }
    if name.chars().count() > 80 || name.contains(['\n', '\r']) {
        return Err(format!(
            "Der Name für {what} ist zu lang (höchstens 80 Zeichen)."
        ));
    }
    Ok(name.to_string())
}

/// Validated account form: name plus the colour picked in the palette (`None` = unchanged).
#[derive(Debug, PartialEq, Eq)]
pub struct AccountForm {
    pub name: String,
    pub color: Option<String>,
}

pub fn validate_account(
    name: &str,
    palette: &[String],
    choice: i32,
) -> Result<AccountForm, String> {
    Ok(AccountForm {
        name: validate_name("das Konto", name)?,
        color: pick_color(palette, choice),
    })
}

/// Validated category form.
#[derive(Debug, PartialEq, Eq)]
pub struct CategoryForm {
    pub name: String,
    pub color: Option<String>,
}

pub fn validate_category(
    name: &str,
    palette: &[String],
    choice: i32,
) -> Result<CategoryForm, String> {
    Ok(CategoryForm {
        name: validate_name("die Kategorie", name)?,
        color: pick_color(palette, choice),
    })
}

fn pick_color(palette: &[String], choice: i32) -> Option<String> {
    usize::try_from(choice)
        .ok()
        .and_then(|i| palette.get(i))
        .and_then(|c| normalize_color(c))
}

/// Colour for a new category: the pick, else the first palette colour, else a neutral grey.
pub fn new_category_color(form: &CategoryForm, palette: &[String]) -> String {
    form.color
        .clone()
        .or_else(|| palette.first().and_then(|c| normalize_color(c)))
        .unwrap_or_else(|| "#8E8E93".to_string())
}

/// Two-click gate for destructive actions: the first press arms the target, a second press on
/// the same target confirms. Changing the selection or closing the dialog disarms it.
#[derive(Debug, Default)]
pub struct DeleteGate {
    armed: Option<i64>,
}

impl DeleteGate {
    /// `true` when this press confirms a delete of `id`.
    pub fn press(&mut self, id: i64) -> bool {
        if self.armed == Some(id) {
            self.armed = None;
            true
        } else {
            self.armed = Some(id);
            false
        }
    }

    pub fn reset(&mut self) {
        self.armed = None;
    }

    #[cfg(test)]
    pub fn is_armed(&self) -> bool {
        self.armed.is_some()
    }
}

/// An account can only be deleted once it is archived (the core enforces the same rule).
pub fn can_delete_account(archived: bool) -> bool {
    archived
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> Context {
        Context {
            unlocked: true,
            busy: false,
            can_transfer: true,
            modals: Modals::default(),
        }
    }

    fn palette() -> Vec<String> {
        vec!["#ff3b30".into(), "#0A84FF".into()]
    }

    #[test]
    fn ctrl_shortcuts_route_to_commands() {
        let c = ctx();
        assert_eq!(route("f", true, &c), Some(Command::FocusSearch));
        assert_eq!(route("l", true, &c), Some(Command::Lock));
        assert_eq!(route("r", true, &c), Some(Command::Refresh));
        assert_eq!(route("\u{f708}", false, &c), Some(Command::Refresh));
        assert_eq!(route("i", true, &c), Some(Command::Import));
        assert_eq!(route("n", true, &c), Some(Command::NewTransfer));
        // upper case (Caps Lock / Shift) and control characters are the same keys
        assert_eq!(route("F", true, &c), Some(Command::FocusSearch));
        assert_eq!(route("\u{6}", true, &c), Some(Command::FocusSearch));
        assert_eq!(route("\u{c}", true, &c), Some(Command::Lock));
    }

    #[test]
    fn plain_letters_and_unknown_keys_do_nothing() {
        let c = ctx();
        assert_eq!(route("f", false, &c), None);
        assert_eq!(route("x", true, &c), None);
        assert_eq!(route("", true, &c), None);
        assert_eq!(route("ab", true, &c), None);
    }

    #[test]
    fn locked_vault_ignores_everything() {
        let c = Context {
            unlocked: false,
            ..ctx()
        };
        assert_eq!(route("l", true, &c), None);
        assert_eq!(route("\u{1b}", false, &c), None);
    }

    #[test]
    fn busy_blocks_actions_but_not_search_or_lock() {
        let c = Context {
            busy: true,
            ..ctx()
        };
        assert_eq!(route("r", true, &c), None);
        assert_eq!(route("\u{f708}", false, &c), None);
        assert_eq!(route("i", true, &c), None);
        assert_eq!(route("n", true, &c), None);
        assert_eq!(route("f", true, &c), Some(Command::FocusSearch));
        assert_eq!(route("l", true, &c), Some(Command::Lock));
    }

    #[test]
    fn transfer_needs_a_bank_account() {
        let c = Context {
            can_transfer: false,
            ..ctx()
        };
        assert_eq!(route("n", true, &c), None);
    }

    #[test]
    fn escape_closes_the_top_dialog_only() {
        let mut c = ctx();
        assert_eq!(route("\u{1b}", false, &c), None);
        c.modals.about = true;
        c.modals.categories = true;
        assert_eq!(
            route("\u{1b}", false, &c),
            Some(Command::CloseModal(Modal::Categories))
        );
        c.modals.tan = true;
        assert_eq!(
            route("\u{1b}", false, &c),
            Some(Command::CloseModal(Modal::Tan))
        );
    }

    #[test]
    fn open_dialog_swallows_other_shortcuts() {
        let mut c = ctx();
        c.modals.account = true;
        assert_eq!(route("l", true, &c), None);
        assert_eq!(route("n", true, &c), None);
    }

    #[test]
    fn modal_order() {
        let m = Modals {
            transfer: true,
            add_bank: true,
            ..Modals::default()
        };
        assert_eq!(m.top(), Some(Modal::Transfer));
        assert_eq!(Modals::default().top(), None);
    }

    #[test]
    fn colors_are_normalized() {
        assert_eq!(normalize_color(" #ff3b30 "), Some("#FF3B30".into()));
        assert_eq!(normalize_color("ff3b30"), None);
        assert_eq!(normalize_color("#ff3b3"), None);
        assert_eq!(normalize_color("#gg3b30"), None);
        assert_eq!(palette_index(&palette(), "#0a84ff"), Some(1));
        assert_eq!(palette_index(&palette(), "#000000"), None);
    }

    #[test]
    fn names_are_validated() {
        assert_eq!(validate_name("das Konto", "  Giro  "), Ok("Giro".into()));
        assert!(validate_name("das Konto", "   ").is_err());
        assert!(validate_name("das Konto", "a\nb").is_err());
        assert!(validate_name("das Konto", &"x".repeat(81)).is_err());
        assert!(validate_name("das Konto", &"x".repeat(80)).is_ok());
    }

    #[test]
    fn account_form_keeps_color_only_when_picked() {
        let p = palette();
        let f = validate_account("Bar", &p, 1).unwrap();
        assert_eq!(
            f,
            AccountForm {
                name: "Bar".into(),
                color: Some("#0A84FF".into())
            }
        );
        assert_eq!(validate_account("Bar", &p, -1).unwrap().color, None);
        assert_eq!(validate_account("Bar", &p, 9).unwrap().color, None);
        assert!(validate_account("", &p, 0).is_err());
    }

    #[test]
    fn new_category_falls_back_to_palette_then_grey() {
        let p = palette();
        let none = validate_category("Auto", &p, -1).unwrap();
        assert_eq!(new_category_color(&none, &p), "#FF3B30");
        assert_eq!(new_category_color(&none, &[]), "#8E8E93");
        let picked = validate_category("Auto", &p, 1).unwrap();
        assert_eq!(new_category_color(&picked, &p), "#0A84FF");
    }

    #[test]
    fn delete_needs_two_presses_on_the_same_target() {
        let mut g = DeleteGate::default();
        assert!(!g.press(7));
        assert!(g.is_armed());
        assert!(!g.press(8)); // other target: re-armed, not confirmed
        assert!(g.press(8));
        assert!(!g.is_armed());
        assert!(!g.press(8));
        g.reset();
        assert!(!g.is_armed());
    }

    #[test]
    fn only_archived_accounts_can_be_deleted() {
        assert!(!can_delete_account(false));
        assert!(can_delete_account(true));
    }
}
