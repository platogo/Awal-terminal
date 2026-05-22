/// Unified diff parser — splits a diff into hunks for per-hunk accept/reject.

#[derive(Debug, Clone)]
pub struct DiffHunk {
    pub header: String,
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
    pub lines: Vec<DiffLine>,
}

#[derive(Debug, Clone)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    pub content: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum DiffLineKind {
    Context = 0,
    Add = 1,
    Remove = 2,
}

/// Parse a unified diff string into hunks.
pub fn parse_hunks(diff_text: &str) -> Vec<DiffHunk> {
    let mut hunks = Vec::new();
    let mut current_hunk: Option<DiffHunk> = None;

    for line in diff_text.lines() {
        if line.starts_with("@@") {
            if let Some(h) = current_hunk.take() {
                hunks.push(h);
            }
            let (old_start, old_count, new_start, new_count) = parse_hunk_header(line);
            current_hunk = Some(DiffHunk {
                header: line.to_string(),
                old_start,
                old_count,
                new_start,
                new_count,
                lines: Vec::new(),
            });
        } else if let Some(ref mut hunk) = current_hunk {
            let (kind, content) = if let Some(rest) = line.strip_prefix('+') {
                (DiffLineKind::Add, rest.to_string())
            } else if let Some(rest) = line.strip_prefix('-') {
                (DiffLineKind::Remove, rest.to_string())
            } else if let Some(rest) = line.strip_prefix(' ') {
                (DiffLineKind::Context, rest.to_string())
            } else {
                (DiffLineKind::Context, line.to_string())
            };
            hunk.lines.push(DiffLine { kind, content });
        }
    }

    if let Some(h) = current_hunk {
        hunks.push(h);
    }

    hunks
}

/// Apply selected hunks to produce the new file content.
/// `original` is the original file content, `hunks` are all parsed hunks,
/// `accepted` is a bitmask of which hunks to apply (by index).
pub fn apply_hunks(original: &str, hunks: &[DiffHunk], accepted: &[bool]) -> String {
    let old_lines: Vec<&str> = original.lines().collect();
    let mut result = Vec::new();
    let mut pos: usize = 0; // current position in old_lines (0-indexed)

    for (i, hunk) in hunks.iter().enumerate() {
        let hunk_start = (hunk.old_start as usize).saturating_sub(1);

        // Copy lines before this hunk
        while pos < hunk_start && pos < old_lines.len() {
            result.push(old_lines[pos].to_string());
            pos += 1;
        }

        if accepted.get(i).copied().unwrap_or(false) {
            // Apply hunk: use new lines
            for dl in &hunk.lines {
                match dl.kind {
                    DiffLineKind::Add => result.push(dl.content.clone()),
                    DiffLineKind::Remove => {
                        pos += 1; // skip old line
                    }
                    DiffLineKind::Context => {
                        result.push(dl.content.clone());
                        pos += 1;
                    }
                }
            }
        } else {
            // Reject hunk: keep old lines
            let end = hunk_start + hunk.old_count as usize;
            while pos < end && pos < old_lines.len() {
                result.push(old_lines[pos].to_string());
                pos += 1;
            }
        }
    }

    // Copy remaining lines
    while pos < old_lines.len() {
        result.push(old_lines[pos].to_string());
        pos += 1;
    }

    let mut out = result.join("\n");
    if original.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn parse_hunk_header(line: &str) -> (u32, u32, u32, u32) {
    // Format: @@ -old_start,old_count +new_start,new_count @@
    let mut old_start = 0u32;
    let mut old_count = 1u32;
    let mut new_start = 0u32;
    let mut new_count = 1u32;

    if let Some(at_end) = line.find(" @@").or_else(|| {
        if line.ends_with("@@") {
            Some(line.len() - 2)
        } else {
            None
        }
    }) {
        let inner = &line[3..at_end]; // skip "@@ "
        let parts: Vec<&str> = inner.split_whitespace().collect();
        for part in parts {
            if let Some(rest) = part.strip_prefix('-') {
                let nums: Vec<&str> = rest.split(',').collect();
                old_start = nums.first().and_then(|s| s.parse().ok()).unwrap_or(0);
                old_count = nums.get(1).and_then(|s| s.parse().ok()).unwrap_or(1);
            } else if let Some(rest) = part.strip_prefix('+') {
                let nums: Vec<&str> = rest.split(',').collect();
                new_start = nums.first().and_then(|s| s.parse().ok()).unwrap_or(0);
                new_count = nums.get(1).and_then(|s| s.parse().ok()).unwrap_or(1);
            }
        }
    }

    (old_start, old_count, new_start, new_count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_diff() {
        let diff = "@@ -1,3 +1,4 @@\n context\n-old line\n+new line\n+added line\n context2";
        let hunks = parse_hunks(diff);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].old_start, 1);
        assert_eq!(hunks[0].old_count, 3);
        assert_eq!(hunks[0].new_start, 1);
        assert_eq!(hunks[0].new_count, 4);
        assert_eq!(hunks[0].lines.len(), 5);
        assert_eq!(hunks[0].lines[1].kind, DiffLineKind::Remove);
        assert_eq!(hunks[0].lines[2].kind, DiffLineKind::Add);
    }

    #[test]
    fn parse_multiple_hunks() {
        let diff = "@@ -1,2 +1,2 @@\n-a\n+b\n ctx\n@@ -10,2 +10,3 @@\n ctx\n+new\n ctx";
        let hunks = parse_hunks(diff);
        assert_eq!(hunks.len(), 2);
        assert_eq!(hunks[1].old_start, 10);
    }

    #[test]
    fn apply_accept_all() {
        let original = "line1\nold\nline3\n";
        let diff = "@@ -1,3 +1,3 @@\n line1\n-old\n+new\n line3";
        let hunks = parse_hunks(diff);
        let result = apply_hunks(original, &hunks, &[true]);
        assert_eq!(result, "line1\nnew\nline3\n");
    }

    #[test]
    fn apply_reject_all() {
        let original = "line1\nold\nline3\n";
        let diff = "@@ -1,3 +1,3 @@\n line1\n-old\n+new\n line3";
        let hunks = parse_hunks(diff);
        let result = apply_hunks(original, &hunks, &[false]);
        assert_eq!(result, "line1\nold\nline3\n");
    }

    #[test]
    fn apply_partial_hunks() {
        let original = "a\nb\nc\nd\ne\nf\n";
        let diff = "@@ -1,3 +1,3 @@\n-a\n+A\n b\n c\n@@ -5,2 +5,2 @@\n-e\n+E\n f";
        let hunks = parse_hunks(diff);
        // Accept first hunk, reject second
        let result = apply_hunks(original, &hunks, &[true, false]);
        assert_eq!(result, "A\nb\nc\nd\ne\nf\n");
    }
}
