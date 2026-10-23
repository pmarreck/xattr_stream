//! Directory traversal for recursive listing: breadth-first (default) or
//! depth-first pre-order, bytewise-sorted children, optional depth limit.
//! Symlinks are visited but never entered, so link loops cannot recurse.
//! Generic over a lister so ordering is unit-tested on a fake tree; `FsLister`
//! is the real one. Port of src/walk.zig.
use crate::{Error, Status};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
	Other = 0,
	Directory = 1,
	Symlink = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Order {
	BreadthFirst = 0,
	DepthFirst = 1,
}

pub struct Entry {
	pub name: Vec<u8>,
	pub kind: Kind,
}

#[derive(Clone, Copy, Debug)]
pub struct Options {
	pub order: Order,
	/// 0 visits the root alone; `None` is unlimited.
	pub max_depth: Option<usize>,
}

impl Default for Options {
	fn default() -> Self {
		Options { order: Order::BreadthFirst, max_depth: None }
	}
}

/// One callback per visited path. A directory that cannot be listed produces
/// a second visit for the same path with a non-ok `status`, then the walk
/// goes on with its siblings.
pub struct Visit<'a> {
	pub path: &'a [u8],
	pub kind: Kind,
	pub depth: usize,
	pub status: Status,
}

/// Source of directory structure: the real filesystem or a test fake. Paths
/// are encoded bytes (raw on POSIX, WTF-8 on Windows).
pub trait Lister {
	fn kind_of(&self, path: &[u8]) -> Result<Kind, Error>;
	fn children(&self, path: &[u8]) -> Result<Vec<Entry>, Error>;
}

const SEP: u8 = if cfg!(windows) { b'\\' } else { b'/' };

fn is_sep(c: u8) -> bool {
	c == b'/' || (cfg!(windows) && c == b'\\')
}

/// Joins as Zig's std.fs.path.join does: one platform separator between the
/// parts unless the parent already ends with one.
fn join(parent: &[u8], name: &[u8]) -> Vec<u8> {
	let mut p = Vec::with_capacity(parent.len() + 1 + name.len());
	p.extend_from_slice(parent);
	if !parent.is_empty() && !is_sep(parent[parent.len() - 1]) {
		p.push(SEP);
	}
	p.extend_from_slice(name);
	p
}

struct Node {
	path: Vec<u8>,
	kind: Kind,
	depth: usize,
}

/// Walk `root`, calling `visit` for each path; return false from the visitor
/// to stop. Breadth-first visits every child the moment its directory is
/// read (so an entry deleted mid-walk has a microsecond window) and queues
/// only directories; depth-first pops a stack of nodes for classic pre-order.
pub fn walk(lister: &impl Lister, root: &[u8], opts: Options, mut visit: impl FnMut(&Visit) -> bool) -> Result<(), Error> {
	let root_kind = lister.kind_of(root)?;
	if !visit(&Visit { path: root, kind: root_kind, depth: 0, status: Status::Ok }) {
		return Ok(());
	}
	if root_kind != Kind::Directory || opts.max_depth == Some(0) {
		return Ok(());
	}
	let mut pending = vec![Node { path: root.to_vec(), kind: Kind::Directory, depth: 0 }];
	let mut head = 0;
	loop {
		let node = match opts.order {
			Order::BreadthFirst => {
				if head >= pending.len() {
					return Ok(());
				}
				head += 1;
				std::mem::replace(&mut pending[head - 1], Node { path: Vec::new(), kind: Kind::Other, depth: 0 })
			}
			Order::DepthFirst => match pending.pop() {
				Some(n) => n,
				None => return Ok(()),
			},
		};
		if opts.order == Order::DepthFirst {
			if node.depth > 0 && !visit(&Visit { path: &node.path, kind: node.kind, depth: node.depth, status: Status::Ok }) {
				return Ok(());
			}
			if node.kind != Kind::Directory {
				continue;
			}
			if let Some(m) = opts.max_depth {
				if node.depth >= m {
					continue;
				}
			}
		}
		let mut kids = match lister.children(&node.path) {
			Ok(k) => k,
			Err(e) => {
				if !visit(&Visit { path: &node.path, kind: node.kind, depth: node.depth, status: Status::of(Some(e)) }) {
					return Ok(());
				}
				continue;
			}
		};
		kids.sort_by(|a, b| a.name.cmp(&b.name));
		let child_depth = node.depth + 1;
		let expand_children = opts.max_depth.map_or(true, |m| child_depth < m);
		match opts.order {
			Order::BreadthFirst => {
				for k in kids {
					let child = join(&node.path, &k.name);
					if !visit(&Visit { path: &child, kind: k.kind, depth: child_depth, status: Status::Ok }) {
						return Ok(());
					}
					if k.kind == Kind::Directory && expand_children {
						pending.push(Node { path: child, kind: k.kind, depth: child_depth });
					}
				}
			}
			// Depth-first pops from the back, so push in reverse to pop ascending.
			Order::DepthFirst => {
				for k in kids.into_iter().rev() {
					pending.push(Node { path: join(&node.path, &k.name), kind: k.kind, depth: child_depth });
				}
			}
		}
	}
}

/// The real filesystem. Entry kinds come from the directory listing itself;
/// on filesystems that do not report them, Rust falls back to lstat, so a
/// subdirectory is still recognized.
pub struct FsLister;

#[cfg(windows)]
fn map_io_error(e: &std::io::Error) -> Error {
	// ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_DIRECTORY;
	// ERROR_ACCESS_DENIED; ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY;
	// ERROR_INVALID_NAME, ERROR_FILENAME_EXCED_RANGE.
	match e.raw_os_error().unwrap_or(-1) {
		2 | 3 | 267 => Error::NotFound,
		5 => Error::Permission,
		8 | 14 => Error::OutOfMemory,
		123 | 206 => Error::InvalidPath,
		_ => Error::Io,
	}
}

#[cfg(unix)]
fn map_io_error(e: &std::io::Error) -> Error {
	let code = e.raw_os_error().unwrap_or(-1);
	match e.kind() {
		std::io::ErrorKind::NotFound => Error::NotFound,
		std::io::ErrorKind::PermissionDenied => Error::Permission,
		std::io::ErrorKind::OutOfMemory => Error::OutOfMemory,
		_ if code == crate::os::ENOTDIR => Error::NotFound,
		_ if code == crate::os::ENAMETOOLONG => Error::InvalidPath,
		_ => Error::Io,
	}
}

fn kind_of_type(t: std::fs::FileType) -> Kind {
	if t.is_symlink() {
		Kind::Symlink
	} else if t.is_dir() {
		Kind::Directory
	} else {
		Kind::Other
	}
}

impl Lister for FsLister {
	fn kind_of(&self, path: &[u8]) -> Result<Kind, Error> {
		let p = crate::os::path_from_bytes(path).ok_or(Error::InvalidPath)?;
		let md = std::fs::symlink_metadata(p).map_err(|e| map_io_error(&e))?;
		Ok(kind_of_type(md.file_type()))
	}

	fn children(&self, path: &[u8]) -> Result<Vec<Entry>, Error> {
		let p = crate::os::path_from_bytes(path).ok_or(Error::InvalidPath)?;
		let mut out = Vec::new();
		for entry in std::fs::read_dir(p).map_err(|e| map_io_error(&e))? {
			let entry = entry.map_err(|e| map_io_error(&e))?;
			let kind = kind_of_type(entry.file_type().map_err(|e| map_io_error(&e))?);
			out.push(Entry { name: crate::os::bytes_from_os(&entry.file_name()), kind });
		}
		Ok(out)
	}
}

#[cfg(test)]
mod tests {
	//! Ported from src/walk_test.zig: ordering over a fake tree.
	use super::*;
	use std::cell::RefCell;

	fn norm(p: &[u8]) -> String {
		String::from_utf8_lossy(p).replace('\\', "/")
	}

	/// r/ { b/ {z}, a/ {y, x/ {deep}}, f1, l -> symlink }. "r/b" refuses to
	/// be listed when `deny_b` is set.
	struct FakeTree {
		deny_b: bool,
	}

	impl Lister for FakeTree {
		fn kind_of(&self, path: &[u8]) -> Result<Kind, Error> {
			Ok(match norm(path).as_str() {
				"r/l" => Kind::Symlink,
				"r" | "r/a" | "r/b" | "r/a/x" => Kind::Directory,
				"missing" => return Err(Error::NotFound),
				_ => Kind::Other,
			})
		}

		fn children(&self, path: &[u8]) -> Result<Vec<Entry>, Error> {
			use Kind::*;
			let raw: &[(&str, Kind)] = match norm(path).as_str() {
				"r" => &[("b", Directory), ("a", Directory), ("f1", Other), ("l", Symlink)],
				"r/a" => &[("y", Other), ("x", Directory)],
				"r/a/x" => &[("deep", Other)],
				"r/b" if self.deny_b => return Err(Error::Permission),
				"r/b" => &[("z", Other)],
				// Listing anything else (e.g. the symlink) is a walker bug.
				_ => return Err(Error::Io),
			};
			Ok(raw.iter().map(|(n, k)| Entry { name: n.as_bytes().to_vec(), kind: *k }).collect())
		}
	}

	fn run(tree: &FakeTree, root: &str, opts: Options, stop_at: Option<&str>) -> Result<String, Error> {
		let mut out = String::new();
		walk(tree, root.as_bytes(), opts, |v| {
			let kind = match v.kind {
				Kind::Other => "other",
				Kind::Directory => "directory",
				Kind::Symlink => "symlink",
			};
			let bang = if v.status != Status::Ok { " !" } else { "" };
			out.push_str(&format!("{} {} {}{}\n", v.depth, kind, norm(v.path), bang));
			stop_at != Some(norm(v.path).as_str())
		})?;
		Ok(out)
	}

	const OPEN: FakeTree = FakeTree { deny_b: false };

	#[test]
	fn breadth_first_each_level_in_bytewise_order_symlinks_never_entered() {
		assert_eq!(
			run(&OPEN, "r", Options::default(), None).unwrap(),
			"0 directory r\n1 directory r/a\n1 directory r/b\n1 other r/f1\n1 symlink r/l\n2 directory r/a/x\n2 other r/a/y\n2 other r/b/z\n3 other r/a/x/deep\n"
		);
	}

	#[test]
	fn depth_first_pre_order_children_in_bytewise_order() {
		assert_eq!(
			run(&OPEN, "r", Options { order: Order::DepthFirst, max_depth: None }, None).unwrap(),
			"0 directory r\n1 directory r/a\n2 directory r/a/x\n3 other r/a/x/deep\n2 other r/a/y\n1 directory r/b\n2 other r/b/z\n1 other r/f1\n1 symlink r/l\n"
		);
	}

	#[test]
	fn depth_limit_zero_is_the_root_alone_one_adds_children() {
		assert_eq!(run(&OPEN, "r", Options { max_depth: Some(0), ..Options::default() }, None).unwrap(), "0 directory r\n");
		let d1 = run(&OPEN, "r", Options { max_depth: Some(1), ..Options::default() }, None).unwrap();
		assert_eq!(d1, "0 directory r\n1 directory r/a\n1 directory r/b\n1 other r/f1\n1 symlink r/l\n");
		assert_eq!(run(&OPEN, "r", Options { order: Order::DepthFirst, max_depth: Some(1) }, None).unwrap(), d1);
	}

	#[test]
	fn an_unlistable_directory_is_reported_in_place_and_the_walk_continues() {
		assert_eq!(
			run(&FakeTree { deny_b: true }, "r", Options::default(), None).unwrap(),
			"0 directory r\n1 directory r/a\n1 directory r/b\n1 other r/f1\n1 symlink r/l\n2 directory r/a/x\n2 other r/a/y\n1 directory r/b !\n3 other r/a/x/deep\n"
		);
	}

	/// Records children() calls relative to visits.
	struct OrderTree {
		log: RefCell<String>,
	}

	impl Lister for OrderTree {
		fn kind_of(&self, path: &[u8]) -> Result<Kind, Error> {
			Ok(if matches!(norm(path).as_str(), "r" | "r/d1" | "r/d2") { Kind::Directory } else { Kind::Other })
		}
		fn children(&self, path: &[u8]) -> Result<Vec<Entry>, Error> {
			self.log.borrow_mut().push_str(&format!("read {}\n", norm(path)));
			let raw: &[(&str, Kind)] = if norm(path) == "r" { &[("d1", Kind::Directory), ("d2", Kind::Directory), ("f", Kind::Other)] } else { &[("leaf", Kind::Other)] };
			Ok(raw.iter().map(|(n, k)| Entry { name: n.as_bytes().to_vec(), kind: *k }).collect())
		}
	}

	#[test]
	fn breadth_first_visits_every_child_before_reading_the_next_directory() {
		let tree = OrderTree { log: RefCell::new(String::new()) };
		walk(&tree, b"r", Options::default(), |v| {
			tree.log.borrow_mut().push_str(&format!("visit {}\n", norm(v.path)));
			true
		})
		.unwrap();
		assert_eq!(tree.log.into_inner(), "visit r\nread r\nvisit r/d1\nvisit r/d2\nvisit r/f\nread r/d1\nvisit r/d1/leaf\nread r/d2\nvisit r/d2/leaf\n");
	}

	#[test]
	fn the_visitor_can_stop_a_file_root_is_alone_a_missing_root_fails() {
		assert_eq!(
			run(&OPEN, "r", Options { order: Order::DepthFirst, max_depth: None }, Some("r/a/x")).unwrap(),
			"0 directory r\n1 directory r/a\n2 directory r/a/x\n"
		);
		assert_eq!(run(&OPEN, "r/f1", Options::default(), None).unwrap(), "0 other r/f1\n");
		assert_eq!(run(&OPEN, "missing", Options::default(), None), Err(Error::NotFound));
	}

	#[test]
	fn join_adds_one_separator_unless_the_parent_ends_with_one() {
		let s = SEP as char;
		assert_eq!(norm(&join(b"a", b"b")), "a/b");
		assert_eq!(norm(&join(b"a/", b"b")), "a/b");
		assert_eq!(norm(&join(b"/", b"b")), "/b");
		assert_eq!(String::from_utf8_lossy(&join(b"a", b"b")), format!("a{s}b"));
	}
}
