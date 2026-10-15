//! Embeds every `migrations/*.sql` file, ordered by name, as `MIGRATIONS`.

use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-changed=migrations");
    let dir = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("migrations");
    let mut files: Vec<_> = fs::read_dir(&dir)
        .expect("migrations directory")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "sql"))
        .collect();
    files.sort();
    let mut out = String::from("pub const MIGRATIONS: &[(&str, &str)] = &[\n");
    for f in &files {
        let name = f.file_stem().unwrap().to_string_lossy();
        out.push_str(&format!(
            "    ({name:?}, include_str!({:?})),\n",
            f.display().to_string()
        ));
    }
    out.push_str("];\n");
    fs::write(
        Path::new(&env::var("OUT_DIR").unwrap()).join("migrations.rs"),
        out,
    )
    .unwrap();
}
