//! The order a client sends its files in. The server writes them in arrival
//! order, so this is the order the files reach the disk.

use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::str::FromStr;

use anyhow::bail;

use crate::rel_path::RelPath;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Order {
    /// Path order: a folder's files back to back.
    Walk,
    /// Consecutive files in different folders ([spread_across_folders]).
    Spread,
}

impl Order {
    /// [items], given in path order, in this order.
    pub fn arrange<T>(self, items: Vec<T>, path: impl Fn(&T) -> &RelPath) -> Vec<T> {
        match self {
            Order::Walk => items,
            Order::Spread => spread_across_folders(items, path),
        }
    }
}

impl FromStr for Order {
    type Err = anyhow::Error;

    fn from_str(text: &str) -> anyhow::Result<Self> {
        match text {
            "walk" => Ok(Order::Walk),
            "spread" => Ok(Order::Spread),
            _ => bail!("order is walk or spread, not {text:?}"),
        }
    }
}

impl fmt::Display for Order {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Order::Walk => "walk",
            Order::Spread => "spread",
        })
    }
}

/// [items] reordered so that consecutive ones sit in different parent
/// folders: one from each folder in turn, round robin, the folders in the
/// order they first appear and each folder's own items in their given order.
/// The Dart apply's `spreadAcrossFolders` (SPEC §7.2, task 5d8c28), for the
/// same reason: on Android's shared storage, creates in one folder serialise,
/// so the writes in flight at once should be in different folders.
fn spread_across_folders<T>(items: Vec<T>, path: impl Fn(&T) -> &RelPath) -> Vec<T> {
    // Each folder's queue, in the order the folders first appear.
    let mut queues: Vec<VecDeque<T>> = Vec::new();
    let mut slots: HashMap<String, usize> = HashMap::new();
    for item in items {
        let folder = path(&item).folder().to_string();
        let slot = *slots.entry(folder).or_insert_with(|| {
            queues.push(VecDeque::new());
            queues.len() - 1
        });
        queues[slot].push_back(item);
    }
    let mut spread = Vec::new();
    while !queues.is_empty() {
        for queue in &mut queues {
            spread.extend(queue.pop_front());
        }
        queues.retain(|queue| !queue.is_empty());
    }
    spread
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(texts: &[&str]) -> Vec<RelPath> {
        texts.iter().map(|t| RelPath::parse(t).unwrap()).collect()
    }

    fn texts(paths: &[RelPath]) -> Vec<&str> {
        paths.iter().map(RelPath::as_str).collect()
    }

    #[test]
    fn spread_takes_one_file_per_folder_in_turn() {
        let walked = paths(&["a/1", "a/2", "a/3", "b/1", "c/1", "c/2", "top"]);
        let spread = Order::Spread.arrange(walked, |p| p);
        assert_eq!(
            texts(&spread),
            ["a/1", "b/1", "c/1", "top", "a/2", "c/2", "a/3"]
        );
    }

    #[test]
    fn walk_keeps_the_given_order() {
        let walked = paths(&["a/1", "a/2", "b/1"]);
        let kept = Order::Walk.arrange(walked, |p| p);
        assert_eq!(texts(&kept), ["a/1", "a/2", "b/1"]);
    }

    #[test]
    fn orders_parse_from_their_names() {
        assert_eq!("walk".parse::<Order>().unwrap(), Order::Walk);
        assert_eq!("spread".parse::<Order>().unwrap(), Order::Spread);
        assert!("random".parse::<Order>().is_err());
    }
}
