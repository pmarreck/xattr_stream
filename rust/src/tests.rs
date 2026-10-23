//! Core tests ported from src/xattr_stream_test.zig. The fake-adapter tests
//! pin the optimistic read and the bounded retry; the integration tests use
//! private temporary directories only, never a user's files.
use super::*;
use std::cell::Cell;
use std::path::PathBuf;

struct Fixture {
	dir: PathBuf,
}

impl Fixture {
	/// A fresh directory under the system temp dir. When that filesystem
	/// cannot hold attributes at all, the test fails, unless
	/// XS_EXPECT_UNSUPPORTED=1 says so up front (the Nix build sandbox, which
	/// refuses setxattr); then it returns None and the test does nothing.
	/// Rust has no skipped state, so a silent early return would read as a
	/// pass.
	fn new(tag: &str) -> Option<Fixture> {
		static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
		let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
		let dir = std::env::temp_dir().join(format!("xattr_stream_rs-{}-{}-{}", std::process::id(), tag, n));
		std::fs::create_dir_all(&dir).unwrap();
		let fx = Fixture { dir };
		let probe = fx.file("probe");
		match set(&probe, b"probe", b"x", &Options::default()) {
			Err(Error::Unsupported) => {
				assert!(
					std::env::var_os("XS_EXPECT_UNSUPPORTED").is_some_and(|v| v == "1"),
					"{} does not support attributes; set XS_EXPECT_UNSUPPORTED=1 where that is expected",
					fx.dir.display()
				);
				None
			}
			r => {
				r.unwrap();
				Some(fx)
			}
		}
	}

	fn path(&self, name: &str) -> Vec<u8> {
		os::bytes_from_os(self.dir.join(name).as_os_str())
	}

	fn file(&self, name: &str) -> Vec<u8> {
		std::fs::write(self.dir.join(name), b"").unwrap();
		self.path(name)
	}
}

impl Drop for Fixture {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.dir);
	}
}

const D: Options = Options { follow_symlinks: true, raw_names: false, max_value_len: DEFAULT_MAX_VALUE_LEN };

#[test]
fn round_trip_every_byte_value_size_and_bytes_exact() {
	let Some(fx) = Fixture::new("rt") else { return };
	let f = fx.file("f");
	let value: Vec<u8> = (0..=255u8).collect();
	set(&f, b"llc.mecha.probe", &value, &D).unwrap();
	assert_eq!(size(&f, b"llc.mecha.probe", &D), Ok(256));
	assert_eq!(get(&f, b"llc.mecha.probe", &D).unwrap(), value);
}

#[test]
fn empty_value_is_present_not_missing() {
	let Some(fx) = Fixture::new("empty") else { return };
	let f = fx.file("f");
	set(&f, b"empty", b"", &D).unwrap();
	assert_eq!(size(&f, b"empty", &D), Ok(0));
	assert_eq!(get(&f, b"empty", &D).unwrap(), b"");
	assert_eq!(list(&f, &D).unwrap(), vec![b"empty".to_vec()]);
}

#[test]
fn directories_carry_attributes_too() {
	let Some(fx) = Fixture::new("dir") else { return };
	std::fs::create_dir(fx.dir.join("d")).unwrap();
	let d = fx.path("d");
	set(&d, b"dir.attr", b"a\x00b\n\xff", &D).unwrap();
	assert_eq!(get(&d, b"dir.attr", &D).unwrap(), b"a\x00b\n\xff");
	remove(&d, b"dir.attr", &D).unwrap();
	assert_eq!(size(&d, b"dir.attr", &D), Err(Error::Missing));
}

#[test]
fn missing_attribute_is_missing_for_every_read_and_remove() {
	let Some(fx) = Fixture::new("missing") else { return };
	let f = fx.file("f");
	let mut buf = [0u8; 8];
	assert_eq!(size(&f, b"nope", &D), Err(Error::Missing));
	assert_eq!(get(&f, b"nope", &D), Err(Error::Missing));
	assert_eq!(get_into(&f, b"nope", &mut buf, &D), Err(Error::Missing));
	assert_eq!(remove(&f, b"nope", &D), Err(Error::Missing));
}

#[test]
fn overwrite_replaces_the_whole_value() {
	let Some(fx) = Fixture::new("over") else { return };
	let f = fx.file("f");
	set(&f, b"k", b"first-longer-value", &D).unwrap();
	set(&f, b"k", b"2nd", &D).unwrap();
	assert_eq!(get(&f, b"k", &D).unwrap(), b"2nd");
}

#[test]
fn list_returns_exactly_the_logical_names_sorted_and_remove_drops_them() {
	let Some(fx) = Fixture::new("list") else { return };
	let f = fx.file("f");
	let wanted: [&[u8]; 3] = [b"alpha", b"beta.gamma", "ünï".as_bytes()];
	for n in wanted {
		set(&f, n, n, &D).unwrap();
	}
	assert_eq!(list(&f, &D).unwrap(), wanted.iter().map(|n| n.to_vec()).collect::<Vec<_>>());
	remove(&f, b"beta.gamma", &D).unwrap();
	assert_eq!(list(&f, &D).unwrap().len(), 2);
}

#[test]
fn invalid_names_are_rejected_by_every_operation_before_any_os_call() {
	let Some(fx) = Fixture::new("badname") else { return };
	// Deliberately nonexistent path: InvalidName must win over NotFound.
	let f = fx.path("does-not-exist");
	let mut buf = [0u8; 8];
	for n in [&b""[..], b"a:b", b"..\\x", b"user.foo", b"$DATA", b"Zone.Identifier", b"com.apple.quarantine", b"a\x00b", b"trailing."] {
		assert_eq!(set(&f, n, b"v", &D), Err(Error::InvalidName));
		assert_eq!(size(&f, n, &D), Err(Error::InvalidName));
		assert_eq!(get(&f, n, &D), Err(Error::InvalidName));
		assert_eq!(get_into(&f, n, &mut buf, &D), Err(Error::InvalidName));
		assert_eq!(remove(&f, n, &D), Err(Error::InvalidName));
	}
}

#[test]
fn nonexistent_path_is_not_found_for_every_operation() {
	let Some(fx) = Fixture::new("nf") else { return };
	let f = fx.path("does-not-exist");
	let mut buf = [0u8; 8];
	assert_eq!(set(&f, b"k", b"v", &D), Err(Error::NotFound));
	assert_eq!(size(&f, b"k", &D), Err(Error::NotFound));
	assert_eq!(get(&f, b"k", &D), Err(Error::NotFound));
	assert_eq!(get_into(&f, b"k", &mut buf, &D), Err(Error::NotFound));
	assert_eq!(remove(&f, b"k", &D), Err(Error::NotFound));
	assert_eq!(list(&f, &D), Err(Error::NotFound));
}

#[test]
fn invalid_paths_are_rejected() {
	for p in [&b""[..], b"a\x00b"] {
		assert_eq!(set(p, b"k", b"v", &D), Err(Error::InvalidPath));
		assert_eq!(list(p, &D), Err(Error::InvalidPath));
		assert_eq!(limits(p), -1);
	}
	assert_eq!(get(&vec![b'a'; PATH_BUF_LEN], b"k", &D), Err(Error::InvalidPath));
}

#[test]
fn values_above_max_value_len_are_too_large_on_set_and_get() {
	let Some(fx) = Fixture::new("big") else { return };
	let f = fx.file("f");
	let value = b"0123456789abcdef";
	let at = |n| Options { max_value_len: n, ..D };
	assert_eq!(set(&f, b"k", value, &at(15)), Err(Error::TooLarge));
	set(&f, b"k", value, &at(16)).unwrap();
	assert_eq!(get(&f, b"k", &at(15)), Err(Error::TooLarge));
	assert_eq!(get(&f, b"k", &at(16)).unwrap(), value);
}

#[test]
fn default_value_bound_is_the_smallest_os_ceiling() {
	assert_eq!(DEFAULT_MAX_VALUE_LEN, 65536);
	assert_eq!(PORTABLE_VALUE_LEN, 3916);
	let Some(fx) = Fixture::new("ceiling") else { return };
	let f = fx.file("f");
	assert_eq!(set(&f, b"k", &vec![b'x'; 65537], &D), Err(Error::TooLarge));
	if cfg!(target_os = "linux") {
		assert_eq!(limits(&f), 65536);
	}
}

#[test]
fn get_into_reports_buffer_too_small_and_fills_an_exact_buffer() {
	let Some(fx) = Fixture::new("into") else { return };
	let f = fx.file("f");
	set(&f, b"k", b"hello", &D).unwrap();
	assert_eq!(get_into(&f, b"k", &mut [0u8; 4], &D), Err(Error::BufferTooSmall));
	let mut exact = [0u8; 5];
	assert_eq!(get_into(&f, b"k", &mut exact, &D), Ok(5));
	assert_eq!(&exact, b"hello");
	assert_eq!(get_into(&f, b"k", &mut [], &D), Err(Error::BufferTooSmall));
}

#[cfg(unix)]
#[test]
fn symlink_policy_follow_reaches_the_target_nofollow_addresses_the_link() {
	let Some(fx) = Fixture::new("link") else { return };
	let f = fx.file("target");
	std::os::unix::fs::symlink("target", fx.dir.join("link")).unwrap();
	let l = fx.path("link");
	set(&l, b"k", b"via-link", &D).unwrap();
	assert_eq!(size(&f, b"k", &D), Ok(8));
	let nofollow = Options { follow_symlinks: false, ..D };
	if cfg!(target_os = "linux") {
		// Kernel policy: user.* attributes are not permitted on symlinks.
		assert_eq!(set(&l, b"k", b"on-link", &nofollow), Err(Error::Permission));
	} else {
		set(&l, b"k", b"on-link", &nofollow).unwrap();
		assert_eq!(size(&l, b"k", &nofollow), Ok(7));
		assert_eq!(size(&f, b"k", &D), Ok(8));
	}
}

#[test]
fn attributes_survive_rename_but_not_replacement_by_a_fresh_file() {
	let Some(fx) = Fixture::new("rename") else { return };
	let a = fx.file("a");
	set(&a, b"k", b"keep", &D).unwrap();
	std::fs::rename(fx.dir.join("a"), fx.dir.join("b")).unwrap();
	let b = fx.path("b");
	assert_eq!(get(&b, b"k", &D).unwrap(), b"keep");
	fx.file("c");
	std::fs::rename(fx.dir.join("c"), fx.dir.join("b")).unwrap();
	assert_eq!(size(&b, b"k", &D), Err(Error::Missing));
}

#[test]
fn raw_names_address_the_native_name_directly_and_list_natively() {
	let Some(fx) = Fixture::new("raw") else { return };
	let f = fx.file("f");
	let raw = Options { raw_names: true, ..D };
	let native = native_name(b"rawtest", &D).unwrap();
	set(&f, b"rawtest", b"v", &D).unwrap();
	assert_eq!(size(&f, &native, &raw), Ok(1));
	assert!(list(&f, &raw).unwrap().contains(&native));
	remove(&f, &native, &raw).unwrap();
	assert_eq!(size(&f, b"rawtest", &D), Err(Error::Missing));
}

#[test]
fn concurrent_writers_and_readers_on_one_file_never_corrupt_a_value() {
	let Some(fx) = Fixture::new("conc") else { return };
	let f = fx.file("f");
	let failures = std::sync::atomic::AtomicUsize::new(0);
	std::thread::scope(|s| {
		for id in 0..8 {
			let (f, failures) = (&f, &failures);
			s.spawn(move || {
				let name = format!("w{id}");
				for i in 0..200 {
					let v = format!("{id}:{i}");
					let bump = || failures.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
					if set(f, name.as_bytes(), v.as_bytes(), &D).is_err() {
						bump();
						continue;
					}
					// Any read of the shared key must return a whole value.
					if set(f, b"shared", v.as_bytes(), &D).is_err() {
						bump();
					}
					match get(f, b"shared", &D) {
						Ok(got) if got.contains(&b':') => {}
						_ => {
							bump();
						}
					}
				}
			});
		}
	});
	assert_eq!(failures.into_inner(), 0);
	assert_eq!(list(&f, &D).unwrap().len(), 9);
}

/// Fake adapter: records calls and serves values from closures, so the
/// optimistic read and the retry loop are checked without an OS.
struct Fake<S: Fn(usize) -> usize, R: Fn(usize, &mut [u8]) -> Result<usize, Error>> {
	sizes: Cell<usize>,
	reads: Cell<usize>,
	size_fn: S,
	read_fn: R,
}

impl<S: Fn(usize) -> usize, R: Fn(usize, &mut [u8]) -> Result<usize, Error>> Adapter for Fake<S, R> {
	fn size(&self, _: &CStr, _: &CStr, _: bool) -> Result<usize, Error> {
		self.sizes.set(self.sizes.get() + 1);
		Ok((self.size_fn)(self.sizes.get()))
	}
	fn read(&self, _: &CStr, _: &CStr, _: bool, buf: &mut [u8]) -> Result<usize, Error> {
		self.reads.set(self.reads.get() + 1);
		(self.read_fn)(self.sizes.get(), buf)
	}
	fn write(&self, _: &CStr, _: &CStr, _: bool, _: &[u8]) -> Result<(), Error> {
		unreachable!()
	}
	fn remove(&self, _: &CStr, _: &CStr, _: bool) -> Result<(), Error> {
		unreachable!()
	}
	fn list_raw(&self, _: &CStr, _: bool) -> Result<Vec<u8>, Error> {
		unreachable!()
	}
	fn limits(&self, _: &CStr) -> i64 {
		unreachable!()
	}
}

fn fake<S: Fn(usize) -> usize, R: Fn(usize, &mut [u8]) -> Result<usize, Error>>(size_fn: S, read_fn: R) -> Fake<S, R> {
	Fake { sizes: Cell::new(0), reads: Cell::new(0), size_fn, read_fn }
}

const P: &CStr = c"p";
const N: &CStr = c"n";

#[test]
fn get_a_small_value_costs_one_read_and_no_size_query() {
	let small = fake(
		|_| 5,
		|_, buf| {
			if buf.len() < 5 {
				return Err(Error::BufferTooSmall);
			}
			buf[..5].copy_from_slice(b"hello");
			Ok(5)
		},
	);
	assert_eq!(get_with(&small, P, N, false, 1 << 20).unwrap(), b"hello");
	assert_eq!((small.reads.get(), small.sizes.get()), (1, 0));
	// The bound applies even when the value fits the optimistic buffer.
	assert_eq!(get_with(&small, P, N, false, 4), Err(Error::TooLarge));
}

#[test]
fn get_a_value_that_keeps_growing_is_changed_after_bounded_retries() {
	let growing = fake(
		|n| OPTIMISTIC_READ_LEN + n,
		|n, buf| if buf.len() < OPTIMISTIC_READ_LEN + n + 1 { Err(Error::BufferTooSmall) } else { Ok(OPTIMISTIC_READ_LEN + n + 1) },
	);
	assert_eq!(get_with(&growing, P, N, false, 1 << 20), Err(Error::Changed));
	assert_eq!(growing.sizes.get(), MAX_GET_ATTEMPTS);
	assert_eq!(OPTIMISTIC_READ_LEN, 4096);
}

#[test]
fn get_a_value_that_shrinks_is_returned_at_its_actual_length() {
	let shrinking = fake(
		|_| OPTIMISTIC_READ_LEN + 1000,
		|_, buf| {
			if buf.len() < OPTIMISTIC_READ_LEN + 1000 {
				return Err(Error::BufferTooSmall);
			}
			buf[..3].copy_from_slice(b"abc");
			Ok(3)
		},
	);
	assert_eq!(get_with(&shrinking, P, N, false, 1 << 20).unwrap(), b"abc");
}

#[test]
fn status_codes_are_stable_and_named() {
	assert_eq!(Status::of(None).code(), 0);
	assert_eq!(Status::of(Some(Error::Missing)).code(), 1);
	assert_eq!(Status::of(Some(Error::Unsupported)).code(), 2);
	assert_eq!(Status::of(Some(Error::Io)).code(), 12);
	assert_eq!(Status::InvalidArgument.code(), 13);
	assert_eq!(status_name(2), "XS_UNSUPPORTED");
	assert_eq!(status_name(0), "XS_OK");
	assert_eq!(status_name(13), "XS_INVALID_ARGUMENT");
	assert_eq!(status_name(999), "XS_UNKNOWN");
	assert_eq!(status_name(-1), "XS_UNKNOWN");
}

#[test]
fn pack_logical_filters_to_logical_names_and_sorts_bytewise() {
	let raw_linux = b"user.zeta\x00user.alpha\x00security.selinux\x00user.mid\x00user.\x00trusted.x\x00";
	let v = |xs: &[&str]| xs.iter().map(|s| s.as_bytes().to_vec()).collect::<Vec<_>>();
	assert_eq!(pack_logical(raw_linux, names::Os::Linux, &D), v(&["alpha", "mid", "zeta"]));
	assert_eq!(
		pack_logical(raw_linux, names::Os::Linux, &Options { raw_names: true, ..D }),
		v(&["security.selinux", "trusted.x", "user.", "user.alpha", "user.mid", "user.zeta"])
	);
	assert!(pack_logical(b"", names::Os::Windows, &D).is_empty());
}

#[test]
fn display_text_and_utf8_classify_byte_sets() {
	let text: [&[u8]; 6] = [b"hello", b"", b"tab\there", "ünï".as_bytes(), b"0x41 looks like hex but is text", b"  spaces  "];
	let binary: [&[u8]; 8] = [b"a\nb", b"a\r\nb", b"\xff", b"\x00", b"a\x00b", b"\x7f", b"\x1b[31m", b"\xc3"];
	assert!(text.iter().all(|t| is_display_text(t)));
	assert!(binary.iter().all(|b| !is_display_text(b)));
	let utf8: [&[u8]; 7] = [b"", b"plain", b"a\nb\x00c", b"caf\xc3\xa9", b"\xe2\x88\xa3", b"\xf0\x9f\x98\x80", b"dir/sub dir/f"];
	let not: [&[u8]; 8] = [b"\xff", b"caf\xe9", b"\xc3", b"\xc3\x28", b"\xe2\x88", b"\xed\xa0\x80", b"\xc0\xaf", b"\xf4\x90\x80\x80"];
	assert!(utf8.iter().all(|t| is_utf8(t)));
	assert!(not.iter().all(|b| !is_utf8(b)));
}

#[test]
fn platform_is_one_of_the_six_pf_names() {
	let all = ["linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64", "mswin-amd64", "mswin-arm64"];
	assert_eq!(all.iter().filter(|p| **p == PLATFORM).count(), 1);
}
