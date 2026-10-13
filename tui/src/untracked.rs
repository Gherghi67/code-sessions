// ABOUTME: The listing of files a removal would destroy that git keeps no copy of
// ABOUTME: Collapses each directory holding no tracked file to one counted entry, as cs's _untracked_listing_render does

use std::collections::{HashMap, HashSet};

/// One entry of the listing: a directory holding no tracked file (its path
/// ends in '/') with the number of files at risk under it, or a single path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub files: u64,
}

/// Entries a listing shows before it says how many it leaves out.
pub const SHOWN_ENTRIES: usize = 20;

/// The entries for the paths at risk in a checkout whose tracked paths are
/// `tracked`: each path falls under its topmost ancestor directory that holds
/// no tracked file, or stands alone when its parent holds one. git lists a
/// nested repository as one path ending in '/'; `inside` holds the number of
/// files under each. Entries holding the most files come first, then by path.
pub fn entries(tracked: &[String], inside: &HashMap<String, u64>, at_risk: &[String]) -> Result<Vec<Entry>, String> {
    let mut holds_tracked: HashSet<&str> = HashSet::new();
    for path in tracked {
        for (cut, _) in path.match_indices('/') {
            holds_tracked.insert(&path[..=cut]);
        }
    }
    let mut files_under: HashMap<&str, u64> = HashMap::new();
    for path in at_risk {
        let files = if path.ends_with('/') {
            *inside.get(path).ok_or_else(|| format!("no file count for the directory {path}"))?
        } else {
            1
        };
        let entry = path
            .match_indices('/')
            .map(|(cut, _)| &path[..=cut])
            .find(|dir| !holds_tracked.contains(dir))
            .unwrap_or(path);
        *files_under.entry(entry).or_insert(0) += files;
    }
    let mut entries: Vec<Entry> =
        files_under.into_iter().map(|(path, files)| Entry { path: path.to_string(), files }).collect();
    entries.sort_by(|a, b| b.files.cmp(&a.files).then_with(|| a.path.cmp(&b.path)));
    Ok(entries)
}

/// `n` with a comma between each group of three digits.
fn grouped(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

fn files_phrase(n: u64) -> String {
    format!("{} {}", grouped(n), if n == 1 { "file" } else { "files" })
}

/// How many files the entries hold, as the listing's header names them:
/// "1 file", "60,882 files".
pub fn count_phrase(entries: &[Entry]) -> String {
    files_phrase(entries.iter().map(|e| e.files).sum())
}

/// The listing's lines under its header: the first `shown` entries, indented
/// four spaces, a directory with its file count in a column past the longest
/// directory shown; then how many entries are left out, when any are.
pub fn entry_lines(entries: &[Entry], shown: usize) -> Vec<String> {
    let listed = &entries[..entries.len().min(shown)];
    let width = listed.iter().filter(|e| e.path.ends_with('/')).map(|e| e.path.chars().count()).max().unwrap_or(0);
    let mut lines: Vec<String> = listed
        .iter()
        .map(|e| {
            if e.path.ends_with('/') {
                format!("    {:<width$}  ({})", e.path, files_phrase(e.files))
            } else {
                format!("    {}", e.path)
            }
        })
        .collect();
    if entries.len() > shown {
        lines.push(format!("    ... and {} more", grouped((entries.len() - shown) as u64)));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    // cs and the TUI share one listing format, pinned by one fixture both
    // render: input.txt holds the tracked paths, the file count of each
    // directory git does not list into, and the paths at risk, separated by
    // empty lines; expected.txt holds the count phrase, then the entry lines.
    #[test]
    fn listing_renders_the_shared_fixture() {
        let input = include_str!("../../tests/fixtures/untracked-listing/input.txt");
        let expected = include_str!("../../tests/fixtures/untracked-listing/expected.txt");
        let sections: Vec<Vec<String>> =
            input.split("\n\n").map(|s| s.lines().map(str::to_string).collect()).collect();
        assert_eq!(sections.len(), 3, "tracked paths, nested counts, paths at risk");
        let inside: HashMap<String, u64> = sections[1]
            .iter()
            .map(|line| {
                let (files, path) = line.split_once('\t').expect("count, tab, path");
                (path.to_string(), files.parse().expect("a file count"))
            })
            .collect();

        let entries = entries(&sections[0], &inside, &sections[2]).unwrap();
        let mut got = vec![count_phrase(&entries)];
        got.extend(entry_lines(&entries, SHOWN_ENTRIES));

        assert_eq!(got, expected.lines().collect::<Vec<_>>());
    }

    #[test]
    fn a_nested_repository_without_a_file_count_is_an_error() {
        let got = entries(&[], &HashMap::new(), &["vendor/dep/".to_string()]);

        assert_eq!(got, Err("no file count for the directory vendor/dep/".to_string()));
    }
}
