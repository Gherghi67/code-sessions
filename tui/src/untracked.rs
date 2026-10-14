// ABOUTME: The listing of files a removal would destroy that git keeps no copy of
// ABOUTME: Collapses each directory holding no tracked file to one counted entry, as cs's _untracked_listing_render does

use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};

use unicode_width::UnicodeWidthStr;

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
/// files under each. Entries holding the most files come first, then by path
/// in the order cs lists them (`line_form`).
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
    entries.sort_by_cached_key(|e| (Reverse(e.files), line_form(&e.path)));
    Ok(entries)
}

/// A path as cs writes it on one line of a list: a backslash in a name as
/// `\\`, a newline as `\n`. cs orders its entries by the bytes of this form.
fn line_form(path: &str) -> String {
    path.replace('\\', "\\\\").replace('\n', "\\n")
}

/// A path as the listing prints it: a newline in a name as '?', so every
/// entry is one line.
fn printed(path: &str) -> String {
    path.replace('\n', "?")
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
/// directory shown, measured in the columns each takes on screen; then how
/// many entries are left out, when any are.
pub fn entry_lines(entries: &[Entry], shown: usize) -> Vec<String> {
    entry_lines_within(entries, shown, usize::MAX)
}

/// `entry_lines` for a place `columns` wide: a path that would take its line
/// past that is shortened in the middle with '…', so every entry is one row
/// there. Directories keep their file counts in one column.
pub fn entry_lines_within(entries: &[Entry], shown: usize, columns: usize) -> Vec<String> {
    const INDENT: &str = "    ";
    let listed = &entries[..entries.len().min(shown)];
    let counts: Vec<Option<String>> =
        listed.iter().map(|e| e.path.ends_with('/').then(|| format!("  ({})", files_phrase(e.files)))).collect();
    let widest_count = counts.iter().flatten().map(|count| count.width()).max().unwrap_or(0);
    let file_room = columns.saturating_sub(INDENT.len());
    let directory_room = file_room.saturating_sub(widest_count);
    let paths: Vec<String> = listed
        .iter()
        .zip(&counts)
        .map(|(e, count)| shortened(&printed(&e.path), if count.is_some() { directory_room } else { file_room }))
        .collect();
    let width = paths.iter().zip(&counts).filter(|(_, count)| count.is_some()).map(|(p, _)| p.width()).max().unwrap_or(0);
    let mut lines: Vec<String> = paths
        .iter()
        .zip(&counts)
        .map(|(path, count)| match count {
            Some(count) => format!("{INDENT}{path}{}{count}", " ".repeat(width - path.width())),
            None => format!("{INDENT}{path}"),
        })
        .collect();
    if entries.len() > shown {
        lines.push(format!("{INDENT}... and {} more", grouped((entries.len() - shown) as u64)));
    }
    lines
}

/// `text`, or when it takes more than `room` columns, its start and its end
/// around a '…': as much of each as fits, the start getting the odd column.
fn shortened(text: &str, room: usize) -> String {
    if text.width() <= room {
        return text.to_string();
    }
    let kept = room.saturating_sub(1);
    let end_room = kept / 2;
    let mut start = String::new();
    for c in text.chars() {
        start.push(c);
        if start.width() > kept - end_room {
            start.pop();
            break;
        }
    }
    let mut end = String::new();
    for c in text.chars().rev() {
        end.insert(0, c);
        if end.width() > end_room {
            end.remove(0);
            break;
        }
    }
    format!("{start}…{end}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The name a line of the fixture stands for: cs writes a name on one
    /// line with a backslash in it as `\\` and a newline as `\n`.
    fn name_of(line: &str) -> String {
        let mut name = String::new();
        let mut chars = line.chars();
        while let Some(c) = chars.next() {
            if c != '\\' {
                name.push(c);
                continue;
            }
            match chars.next() {
                Some('\\') => name.push('\\'),
                Some('n') => name.push('\n'),
                other => panic!("a backslash followed by {other:?} in the fixture line {line:?}"),
            }
        }
        name
    }

    // cs and the TUI share one listing format, pinned by one fixture both
    // render: input.txt holds the tracked paths, the file count of each
    // directory git does not list into, and the paths at risk, separated by
    // empty lines; expected.txt holds the count phrase, then the entry lines.
    // A path is written as cs lists it, one per line (`name_of` reads it
    // back). The fixture holds a name with a newline and one with an escape
    // and a tab, each control character printing as '?', and a directory
    // named in two-byte characters, which pads by columns.
    #[test]
    fn listing_renders_the_shared_fixture() {
        let input = include_str!("../../tests/fixtures/untracked-listing/input.txt");
        let expected = include_str!("../../tests/fixtures/untracked-listing/expected.txt");
        let sections: Vec<Vec<&str>> = input.split("\n\n").map(|s| s.lines().collect()).collect();
        assert_eq!(sections.len(), 3, "tracked paths, nested counts, paths at risk");
        let names = |lines: &[&str]| lines.iter().map(|line| name_of(line)).collect::<Vec<String>>();
        let inside: HashMap<String, u64> = sections[1]
            .iter()
            .map(|line| {
                let (files, path) = line.split_once('\t').expect("count, tab, path");
                (name_of(path), files.parse().expect("a file count"))
            })
            .collect();

        let entries = entries(&names(&sections[0]), &inside, &names(&sections[2])).unwrap();
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
