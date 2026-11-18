use super::*;

fn vault(dir: &crate::test_support::TempDir) -> std::sync::Arc<Vault> {
    Vault::open(dir.join("v.db").to_string_lossy().into(), vec![7; 32]).unwrap()
}

fn add(v: &Vault, name: &str, parent: Option<i64>) -> i64 {
    v.create_category(name.into(), parent, "tag".into(), "#808080".into())
        .unwrap()
}

/// Names of the children of `parent` in tree order.
fn children(v: &Vault, parent: Option<i64>) -> Vec<String> {
    v.list_categories(None, None)
        .unwrap()
        .into_iter()
        .filter(|c| c.parent_id == parent)
        .map(|c| c.name)
        .collect()
}

#[test]
fn reorders_siblings_under_the_same_parent() {
    let dir = crate::test_support::TempDir::new("cat-reorder-siblings");
    let v = vault(&dir);
    let a = add(&v, "A", None);
    let b = add(&v, "B", None);
    let c = add(&v, "C", None);
    v.reorder_categories(None, vec![c, a, b]).unwrap();
    assert_eq!(children(&v, None), ["C", "A", "B"]);
}

#[test]
fn moves_a_category_to_another_parent_at_a_position() {
    let dir = crate::test_support::TempDir::new("cat-reorder-reparent");
    let v = vault(&dir);
    let p = add(&v, "P", None);
    let x = add(&v, "X", Some(p));
    let y = add(&v, "Y", Some(p));
    let q = add(&v, "Q", None);
    v.reorder_categories(Some(p), vec![x, q, y]).unwrap();
    assert_eq!(children(&v, Some(p)), ["X", "Q", "Y"]);
    assert_eq!(children(&v, None), ["P"]);
}

#[test]
fn can_move_to_the_top_level() {
    let dir = crate::test_support::TempDir::new("cat-reorder-top");
    let v = vault(&dir);
    let p = add(&v, "P", None);
    let x = add(&v, "X", Some(p));
    v.reorder_categories(None, vec![x, p]).unwrap();
    assert_eq!(children(&v, None), ["X", "P"]);
}

#[test]
fn refuses_moving_below_itself_and_changes_nothing() {
    let dir = crate::test_support::TempDir::new("cat-reorder-cycle");
    let v = vault(&dir);
    let p = add(&v, "P", None);
    let k = add(&v, "K", Some(p));
    assert!(v.reorder_categories(Some(k), vec![p]).is_err());
    assert!(v.reorder_categories(Some(p), vec![p]).is_err());
    assert_eq!(children(&v, None), ["P"]);
    assert_eq!(children(&v, Some(p)), ["K"]);
}

#[test]
fn skips_vanished_ids_and_refuses_a_deleted_parent() {
    let dir = crate::test_support::TempDir::new("cat-reorder-gone");
    let v = vault(&dir);
    let a = add(&v, "A", None);
    let b = add(&v, "B", None);
    v.reorder_categories(None, vec![b, 9999, a]).unwrap();
    assert_eq!(children(&v, None), ["B", "A"]);
    let gone = add(&v, "Gone", None);
    v.delete_category(gone).unwrap();
    assert!(v.reorder_categories(Some(gone), vec![a]).is_err());
}
