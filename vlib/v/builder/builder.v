module builder

import (
	os
	time
	v.ast
	v.table
	v.pref
	v.util
	v.vmod
	v.checker
	v.parser
	v.gen
	v.gen.x64
)

pub struct Builder {
pub:
	pref                &pref.Preferences
	table               &table.Table
	checker             checker.Checker
	compiled_dir        string // contains os.real_path() of the dir of the final file beeing compiled, or the dir itself when doing `v .`
	module_path         string
mut:
	module_search_paths []string
	parsed_files        []ast.File
	global_scope        &ast.Scope
	out_name_c          string
}

pub fn new_builder(pref &pref.Preferences) Builder {
	rdir := os.real_path(pref.path)
	compiled_dir := if os.is_dir(rdir) { rdir } else { os.dir(rdir) }
	table := table.new_table()
	return builder.Builder{
		pref: pref
		table: table
		checker: checker.new_checker(table, pref)
		global_scope: &ast.Scope{
			parent: 0
		}
		compiled_dir: compiled_dir
	}
}

pub fn (b mut Builder) gen_c(v_files []string) string {
	t0 := time.ticks()
	b.parsed_files = parser.parse_files(v_files, b.table, b.pref, b.global_scope)
	b.parse_imports()
	t1 := time.ticks()
	parse_time := t1 - t0
	b.info('PARSE: ${parse_time}ms')
	//
	b.checker.check_files(b.parsed_files)
	t2 := time.ticks()
	check_time := t2 - t1
	b.info('CHECK: ${check_time}ms')
	if b.checker.nr_errors > 0 {
		exit(1)
	}
	// println('starting cgen...')
	res := gen.cgen(b.parsed_files, b.table, b.pref)
	t3 := time.ticks()
	gen_time := t3 - t2
	b.info('C GEN: ${gen_time}ms')
	// println('cgen done')
	// println(res)
	return res
}

pub fn (b mut Builder) build_c(v_files []string, out_file string) {
	b.out_name_c = out_file
	b.info('build_c($out_file)')
	mut f := os.create(out_file) or {
		panic(err)
	}
	f.writeln(b.gen_c(v_files))
	f.close()
	// os.write_file(out_file, b.gen_c(v_files))
}

pub fn (b mut Builder) build_x64(v_files []string, out_file string) {
	$if !linux {
		println('v -x64 can only generate Linux binaries for now')
		println('You are not on a Linux system, so you will not ' + 'be able to run the resulting executable')
	}
	t0 := time.ticks()
	b.parsed_files = parser.parse_files(v_files, b.table, b.pref, b.global_scope)
	b.parse_imports()
	t1 := time.ticks()
	parse_time := t1 - t0
	b.info('PARSE: ${parse_time}ms')
	b.checker.check_files(b.parsed_files)
	t2 := time.ticks()
	check_time := t2 - t1
	b.info('CHECK: ${check_time}ms')
	x64.gen(b.parsed_files, out_file)
	t3 := time.ticks()
	gen_time := t3 - t2
	b.info('x64 GEN: ${gen_time}ms')
}

// parse all deps from already parsed files
pub fn (b mut Builder) parse_imports() {
	mut done_imports := []string
	for i in 0 .. b.parsed_files.len {
		ast_file := b.parsed_files[i]
		for _, imp in ast_file.imports {
			mod := imp.mod
			if mod in done_imports {
				continue
			}
			import_path := b.find_module_path(mod, ast_file.path) or {
				// v.parsers[i].error_with_token_index('cannot import module "$mod" (not found)', v.parsers[i].import_table.get_import_tok_idx(mod))
				// break
				// println('module_search_paths:')
				// println(b.module_search_paths)
				panic('cannot import module "$mod" (not found)')
			}
			v_files := b.v_files_from_dir(import_path)
			if v_files.len == 0 {
				// v.parsers[i].error_with_token_index('cannot import module "$mod" (no .v files in "$import_path")', v.parsers[i].import_table.get_import_tok_idx(mod))
				panic('cannot import module "$mod" (no .v files in "$import_path")')
			}
			// Add all imports referenced by these libs
			parsed_files := parser.parse_files(v_files, b.table, b.pref, b.global_scope)
			for file in parsed_files {
				if file.mod.name != mod {
					// v.parsers[pidx].error_with_token_index('bad module definition: ${v.parsers[pidx].file_path} imports module "$mod" but $file is defined as module `$p_mod`', 1
					panic('bad module definition: ${ast_file.path} imports module "$mod" but $file.path is defined as module `$file.mod.name`')
				}
			}
			b.parsed_files << parsed_files
			done_imports << mod
		}
	}
}

pub fn (b Builder) v_files_from_dir(dir string) []string {
	mut res := []string
	if !os.exists(dir) {
		if dir == 'compiler' && os.is_dir('vlib') {
			println('looks like you are trying to build V with an old command')
			println('use `v -o v cmd/v` instead of `v -o v compiler`')
		}
		verror("$dir doesn't exist")
	} else if !os.is_dir(dir) {
		verror("$dir isn't a directory!")
	}
	mut files := os.ls(dir) or {
		panic(err)
	}
	if b.pref.is_verbose {
		println('v_files_from_dir ("$dir")')
	}
	files.sort()
	for file in files {
		if !file.ends_with('.v') && !file.ends_with('.vh') {
			continue
		}
		if file.ends_with('_test.v') {
			continue
		}
		if b.pref.backend == .c && !b.should_compile_c(file) {
			continue
		}
		if b.pref.backend == .js && !b.should_compile_js(file) {
			continue
		}
		if b.pref.compile_defines_all.len > 0 && file.contains('_d_') {
			mut allowed := false
			for cdefine in b.pref.compile_defines {
				file_postfix := '_d_${cdefine}.v'
				if file.ends_with(file_postfix) {
					allowed = true
					break
				}
			}
			if !allowed {
				continue
			}
		}
		res << os.join_path(dir, file)
	}
	return res
}

[inline]
fn (b Builder) should_compile_c(file string) bool {
	if !file.ends_with('.c.v') && file.split('.').len > 2 {
		// Probably something like `a.js.v`.
		return false
	}
	if file.ends_with('_windows.c.v') && b.pref.os != .windows {
		return false
	}
	if file.ends_with('_linux.c.v') && b.pref.os != .linux {
		return false
	}
	if file.ends_with('_darwin.c.v') && b.pref.os != .mac {
		return false
	}
	if file.ends_with('_nix.c.v') && b.pref.os == .windows {
		return false
	}
	if file.ends_with('_android.c.v') && b.pref.os != .android {
		return false
	}
	if file.ends_with('_freebsd.c.v') && b.pref.os != .freebsd {
		return false
	}
	if file.ends_with('_solaris.c.v') && b.pref.os != .solaris {
		return false
	}
	return true
}

[inline]
fn (b Builder) should_compile_js(file string) bool {
	if !file.ends_with('.js.v') && file.split('.').len > 2 {
		// Probably something like `a.c.v`.
		return false
	}
	return true
}

pub fn (b Builder) log(s string) {
	if b.pref.is_verbose {
		println(s)
	}
}

pub fn (b Builder) info(s string) {
	if b.pref.is_verbose {
		println(s)
	}
}

[inline]
fn module_path(mod string) string {
	// submodule support
	return mod.replace('.', os.path_separator)
}

pub fn (b Builder) find_module_path(mod string, fpath string) ?string {
	// support @VROOT/v.mod relative paths:
	vmod_file_location := vmod.mod_file_cacher.get( fpath )
	mod_path := module_path(mod)
	mut module_lookup_paths := []string
	if vmod_file_location.vmod_file.len != 0 && !(vmod_file_location.vmod_folder in b.module_search_paths) {
		module_lookup_paths << vmod_file_location.vmod_folder
	}
	module_lookup_paths << b.module_search_paths
	for search_path in module_lookup_paths {
		try_path := os.join_path(search_path, mod_path)
		if b.pref.is_verbose {
			println('  >> trying to find $mod in $try_path ..')
		}
		if os.is_dir(try_path) {
			if b.pref.is_verbose {
				println('  << found $try_path .')
			}
			return try_path
		}
	}
	smodule_lookup_paths := module_lookup_paths.join(', ')
	return error('module "$mod" not found in:\n$smodule_lookup_paths')
}

fn verror(s string) {
	util.verror('builder error', s)
}
