//! PDF jobs done in the background, no app opening: merge, split, extract, delete pages, rotate, reorder,
//! compress, text, info. Outputs go next to the original (name-merged.pdf …) and never overwrite.

use crate::files::{bytes, unique};
use lopdf::{Dictionary, Document, Object, ObjectId};
use std::path::{Path, PathBuf};

type R<T> = Result<T, String>;

/// "1-3,5", "8-", "last", "each" → 1-based page numbers within 1..=count.
pub fn parse_pages(spec: &str, count: u32) -> R<Vec<u32>> {
    let mut out = vec![];
    for part in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let num = |s: &str| -> R<u32> {
            let s = s.trim();
            if s.eq_ignore_ascii_case("last") || s.eq_ignore_ascii_case("end") {
                return Ok(count);
            }
            s.parse::<u32>().map_err(|_| format!("can't read page {s:?}"))
        };
        if let Some((a, b)) = part.split_once('-') {
            let start = if a.trim().is_empty() { 1 } else { num(a)? };
            let end = if b.trim().is_empty() { count } else { num(b)? };
            if start > end {
                return Err(format!("page range {part} goes backwards"));
            }
            out.extend(start..=end);
        } else {
            out.push(num(part)?);
        }
    }
    if let Some(bad) = out.iter().find(|p| **p == 0 || **p > count) {
        return Err(format!("page {bad} doesn't exist (the PDF has {count} pages)"));
    }
    if out.is_empty() {
        return Err("no pages given".into());
    }
    Ok(out)
}

fn load(p: &Path) -> R<Document> {
    if !p.exists() {
        return Err(format!("no such file: {}", p.display()));
    }
    let doc = Document::load(p).map_err(|e| format!("can't open {} as a PDF: {e}", p.display()))?;
    if doc.is_encrypted() {
        return Err(format!("{} is password-protected", p.display()));
    }
    Ok(doc)
}

fn page_count(doc: &Document) -> u32 {
    doc.get_pages().len() as u32
}

/// A page's dictionary with what it inherits from its parents (MediaBox, Resources, CropBox, Rotate) made explicit,
/// so it stays correct when moved under a new parent.
fn standalone_page(doc: &Document, id: ObjectId) -> Option<Dictionary> {
    let mut dict = doc.get_object(id).ok()?.as_dict().ok()?.clone();
    let mut parent = dict.get(b"Parent").ok().and_then(|p| p.as_reference().ok());
    while let Some(pid) = parent {
        let Ok(pd) = doc.get_object(pid).and_then(|o| o.as_dict()) else { break };
        for key in [&b"MediaBox"[..], b"Resources", b"CropBox", b"Rotate"] {
            if !dict.has(key) {
                if let Ok(v) = pd.get(key) {
                    dict.set(key.to_vec(), v.clone());
                }
            }
        }
        parent = pd.get(b"Parent").ok().and_then(|p| p.as_reference().ok());
    }
    Some(dict)
}

/// A new document from pages of other documents, in the order given ((document, page numbers) pairs).
fn assemble(parts: Vec<(Document, Vec<u32>)>) -> R<Document> {
    let mut out = Document::with_version("1.5");
    let mut max_id = 1;
    let mut pages: Vec<(ObjectId, Dictionary)> = vec![];
    for (mut doc, wanted) in parts {
        doc.renumber_objects_with(max_id);
        max_id = doc.max_id + 1;
        let by_number = doc.get_pages();
        for n in &wanted {
            let id = *by_number.get(n).ok_or_else(|| format!("page {n} doesn't exist"))?;
            let dict = standalone_page(&doc, id).ok_or("a page couldn't be read")?;
            pages.push((id, dict));
        }
        for (id, object) in doc.objects {
            let kind = object.type_name().unwrap_or("").to_string();
            if !matches!(kind.as_str(), "Catalog" | "Pages" | "Page" | "Outlines" | "Outline") {
                out.objects.insert(id, object);
            }
        }
    }
    if pages.is_empty() {
        return Err("no pages to write".into());
    }
    let pages_id = (max_id, 0);
    let catalog_id = (max_id + 1, 0);
    // The same page twice (duplicating) needs its own object.
    let mut kids = vec![];
    let mut used = std::collections::HashSet::new();
    let mut next = max_id + 2;
    for (id, mut dict) in pages {
        dict.set("Parent", Object::Reference(pages_id));
        let id = if used.insert(id) {
            id
        } else {
            next += 1;
            (next, 0)
        };
        out.objects.insert(id, Object::Dictionary(dict));
        kids.push(Object::Reference(id));
    }
    let mut pd = Dictionary::new();
    pd.set("Type", Object::Name(b"Pages".to_vec()));
    pd.set("Count", Object::Integer(kids.len() as i64));
    pd.set("Kids", Object::Array(kids));
    out.objects.insert(pages_id, Object::Dictionary(pd));
    let mut cat = Dictionary::new();
    cat.set("Type", Object::Name(b"Catalog".to_vec()));
    cat.set("Pages", Object::Reference(pages_id));
    out.objects.insert(catalog_id, Object::Dictionary(cat));
    out.trailer.set("Root", Object::Reference(catalog_id));
    out.max_id = next + 1;
    out.renumber_objects();
    out.prune_objects();
    out.compress();
    Ok(out)
}

fn stem(p: &Path) -> String {
    p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "document".into())
}

fn beside(p: &Path, suffix: &str, ext: &str) -> PathBuf {
    unique(&p.with_file_name(format!("{}-{suffix}.{ext}", stem(p))))
}

fn save(mut doc: Document, out: &Path) -> R<String> {
    if let Some(parent) = out.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    doc.save(out).map_err(|e| format!("couldn't save {}: {e}", out.display()))?;
    let size = std::fs::metadata(out).map(|m| m.len()).unwrap_or(0);
    Ok(format!("{} ({}, {} pages)", crate::paths::display(out), bytes(size), page_count(&doc)))
}

/// Runs one job. `out` overrides where the result goes.
pub fn run(op: &str, files: &[PathBuf], opts: &serde_json::Map<String, serde_json::Value>) -> R<String> {
    let s = |k: &str| opts.get(k).and_then(|v| v.as_str().map(String::from).or_else(|| v.as_i64().map(|n| n.to_string())));
    let out = s("out").map(|o| crate::paths::expand(&o));
    let first = files.first().ok_or("pdf needs files")?;
    match op {
        "merge" | "combine" => {
            if files.len() < 2 {
                return Err("merge needs at least two files".into());
            }
            let mut parts = vec![];
            for f in files {
                let d = load(f)?;
                let n = page_count(&d);
                parts.push((d, (1..=n).collect()));
            }
            let target = out.unwrap_or_else(|| beside(first, "merged", "pdf"));
            Ok(format!("merged {} files into {}", files.len(), save(assemble(parts)?, &target)?))
        }
        "extract" => {
            let d = load(first)?;
            let pages = parse_pages(&s("pages").ok_or("extract needs pages, like \"1-3,5\"")?, page_count(&d))?;
            let target = out.unwrap_or_else(|| beside(first, &format!("pages-{}", s("pages").unwrap().replace(',', "_").replace(' ', "")), "pdf"));
            Ok(format!("extracted {} pages into {}", pages.len(), save(assemble(vec![(d, pages)])?, &target)?))
        }
        "split" => {
            let d = load(first)?;
            let count = page_count(&d);
            let spec = s("pages").unwrap_or_else(|| "each".into());
            let groups: Vec<Vec<u32>> = if spec == "each" {
                (1..=count).map(|n| vec![n]).collect()
            } else {
                spec.split(',').map(|g| parse_pages(g, count)).collect::<R<Vec<_>>>()?
            };
            let dir = out.clone().unwrap_or_else(|| first.parent().map(Path::to_path_buf).unwrap_or_default());
            let mut made = vec![];
            for g in groups {
                let name = if g.len() == 1 { format!("{}-page-{}.pdf", stem(first), g[0]) } else { format!("{}-pages-{}-{}.pdf", stem(first), g[0], g[g.len() - 1]) };
                made.push(save(assemble(vec![(load(first)?, g)])?, &unique(&dir.join(name)))?);
            }
            Ok(format!("split into {} files:\n{}", made.len(), made.join("\n")))
        }
        "delete_pages" | "remove_pages" => {
            let d = load(first)?;
            let count = page_count(&d);
            let drop = parse_pages(&s("pages").ok_or("delete_pages needs pages")?, count)?;
            let keep: Vec<u32> = (1..=count).filter(|p| !drop.contains(p)).collect();
            if keep.is_empty() {
                return Err("that would delete every page".into());
            }
            let target = out.unwrap_or_else(|| beside(first, "edited", "pdf"));
            Ok(format!("removed {} pages: {}", count as usize - keep.len(), save(assemble(vec![(d, keep)])?, &target)?))
        }
        "reorder" => {
            let d = load(first)?;
            let order = parse_pages(&s("order").ok_or("reorder needs order, like \"3,1,2\"")?, page_count(&d))?;
            let target = out.unwrap_or_else(|| beside(first, "reordered", "pdf"));
            Ok(format!("reordered pages: {}", save(assemble(vec![(d, order)])?, &target)?))
        }
        "rotate" => {
            let d = load(first)?;
            let count = page_count(&d);
            let degrees = opts.get("degrees").and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))).unwrap_or(90);
            if degrees % 90 != 0 {
                return Err("rotate takes multiples of 90 degrees".into());
            }
            let which = match s("pages") {
                Some(p) => parse_pages(&p, count)?,
                None => (1..=count).collect(),
            };
            let mut doc = assemble(vec![(d, (1..=count).collect())])?;
            for (n, id) in doc.get_pages() {
                if which.contains(&n) {
                    if let Ok(Object::Dictionary(dict)) = doc.get_object_mut(id) {
                        let now = dict.get(b"Rotate").ok().and_then(|r| r.as_i64().ok()).unwrap_or(0);
                        dict.set("Rotate", Object::Integer((now + degrees).rem_euclid(360)));
                    }
                }
            }
            let target = out.unwrap_or_else(|| beside(first, "rotated", "pdf"));
            Ok(format!("rotated {} pages by {degrees}°: {}", which.len(), save(doc, &target)?))
        }
        "compress" => {
            let before = std::fs::metadata(first).map(|m| m.len()).unwrap_or(0);
            let mut d = load(first)?;
            d.prune_objects();
            d.delete_zero_length_streams();
            d.compress();
            let target = out.unwrap_or_else(|| beside(first, "compressed", "pdf"));
            let saved = save(d, &target)?;
            let after = std::fs::metadata(&target).map(|m| m.len()).unwrap_or(0);
            if after >= before {
                let _ = std::fs::remove_file(&target);
                return Ok(format!("{} is already as small as this can make it ({}); nothing saved", crate::paths::display(first), bytes(before)));
            }
            Ok(format!("compressed {} → {saved} (was {})", crate::paths::display(first), bytes(before)))
        }
        "to_text" | "text" => {
            let text = crate::files::pdf_text(first).ok_or("couldn't read text from it (a scan? open it and use read)")?;
            let target = out.unwrap_or_else(|| beside(first, "text", "txt"));
            std::fs::write(&target, &text).map_err(|e| e.to_string())?;
            Ok(format!("saved the text ({} characters) to {}", text.chars().count(), crate::paths::display(&target)))
        }
        "info" => {
            let mut lines = vec![];
            for f in files {
                let size = std::fs::metadata(f).map(|m| m.len()).unwrap_or(0);
                match load(f) {
                    Ok(d) => lines.push(format!("{}: {} pages, {}", crate::paths::display(f), page_count(&d), bytes(size))),
                    Err(e) => lines.push(e),
                }
            }
            Ok(lines.join("\n"))
        }
        other => Err(format!(
            "pdf {other} isn't available on Windows; ops: merge, split, extract, delete_pages, rotate, reorder, compress, to_text, info (for anything else, use a site like ilovepdf.com in the browser)"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_specs() {
        assert_eq!(parse_pages("1-3,5", 10).unwrap(), vec![1, 2, 3, 5]);
        assert_eq!(parse_pages("8-", 10).unwrap(), vec![8, 9, 10]);
        assert_eq!(parse_pages("last", 4).unwrap(), vec![4]);
        assert!(parse_pages("12", 10).is_err());
    }
}
