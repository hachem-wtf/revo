// this file, revo.h is public domain
// auto-generated, editing is futile
package revo

import "core:c"

when ODIN_OS == .Linux {
	foreign import lib "liberevo.a"
}


REVO_VERSION :: "0.1.2"

// a revo value, nanboxed in a single u64
RevoValue :: u64

// tags mirror vm.memory.ValueTag; number never boxed
RevoType :: enum u32 {
	number   = 0,
	string   = 8,
	atom     = 9,
	function = 10,
	table    = 11,
	resource = 12,
	opaque   = 13,
}

// guaranteed to be of these ids
RevoAtom :: enum u32 {
	nil       = 0,
	missing   = 1,
	undef     = 2,
	none      = 3,
	no_result = 4,
	no        = 5,
	false     = 6,

	// false atoms are all which are above
	true      = 7,
	parked    = 8,
	range     = 9,
	ok        = 10,
	err       = 11,
	some      = 12,
}

// nanbox layout: numbers are raw f64 bits, boxed values are
// (REVO_BOX_TAG | (type << 48) | payload)
// payload is an intern id -- pool id for resource --
// except opaque: low 48 ptr bits
REVO_BOX_TAG :: 0x7FF8000000000000
REVO_TAG_SHIFT :: 48
REVO_TAG_MASK :: 0xF
REVO_PAYLOAD_MASK :: 0x0000FFFFFFFFFFFF

// function ptr type; returns REVO_OK (0), anything else raises
// (`*out` used on ok only, ignored on err)
RevoFn :: proc "c" (vm: rawptr, argc: c.size_t, argv: ^RevoValue, out_result: ^RevoValue) -> int

// c errors, returned directly (`return revo_c_err_arity(...)`)
REVO_OK :: 0
REVO_ERR_ARITY :: 1
REVO_ERR_TYPE :: 2
REVO_ERR_OTHER :: 3

// function binding; types live in revo (ascribed re-exports), not here
RevoBinding :: struct {
	name: cstring,
	fn:   RevoFn,
}

@(default_calling_convention = "c", link_prefix = "revo_")
foreign lib {
	/// intern a byte slice, returns stable string id (0 on failure)
	/// `ptr` is borrowed for the call only (not null-terminated)
	/// , `len` is the byte count
	intern :: proc(vm_ptr: rawptr, ptr: cstring, len: c.size_t) -> u64 ---

	/// intern a byte slice as an atom, returns stable atom id (0 on failure)
	intern_atom :: proc(vm_ptr: rawptr, ptr: cstring, len: c.size_t) -> u64 ---

	/// look up a global variable by name, returns nil if missing
	getglobal :: proc(vm_ptr: rawptr, name: cstring, name_len: c.size_t) -> RevoValue ---

	/// set a global variable by name
	setglobal :: proc(vm_ptr: rawptr, name: cstring, name_len: c.size_t, value: RevoValue) ---

	/// create a new empty table, returns nil on failure
	table_create :: proc(vm_ptr: rawptr) -> RevoValue ---

	/// total entries (array part + keyed entries), 0 for non-tables
	table_len :: proc(vm_ptr: rawptr, table: RevoValue) -> u64 ---

	/// array-part length, 0 for non-tables
	table_alen :: proc(vm_ptr: rawptr, table: RevoValue) -> u64 ---

	/// keyed entries length, 0 for non-tables
	table_klen :: proc(vm_ptr: rawptr, table: RevoValue) -> u64 ---

	/// metatable-aware read; true and `out` set when present
	table_get :: proc(vm_ptr: rawptr, table: RevoValue, key: RevoValue, out: ^RevoValue) -> bool ---

	/// metatable-aware write; false on bad table or allocation failure
	table_set :: proc(vm_ptr: rawptr, table: RevoValue, key: RevoValue, value: RevoValue) -> bool ---

	/// delete a table entry, returns true if the key existed
	table_remove :: proc(vm_ptr: rawptr, table: RevoValue, key: RevoValue) -> bool ---

	/// array-part read by index; false when out of range
	table_get_idx :: proc(vm_ptr: rawptr, table: RevoValue, idx: u64, out: ^RevoValue) -> bool ---

	/// append to the array part; false on bad table or allocation failure
	table_push :: proc(vm_ptr: rawptr, table: RevoValue, value: RevoValue) -> bool ---

	/// construct an array table from items, nil on failure
	table_from_items :: proc(vm_ptr: rawptr, count: u64, items: ^RevoValue) -> RevoValue ---

	/// name-keyed write (interns the name); false on bad table or failure
	table_set_name :: proc(vm_ptr: rawptr, table: RevoValue, name: cstring, name_len: c.size_t, value: RevoValue) -> bool ---

	/// name-keyed raw read; true and `out` set when present
	table_get_name :: proc(vm_ptr: rawptr, table: RevoValue, name: cstring, name_len: c.size_t, out: ^RevoValue) -> bool ---

	/// `{:ok, payload}` constructor for host results, nil on failure
	ok :: proc(vm_ptr: rawptr, payload: RevoValue) -> RevoValue ---

	/// `{:err, payload}` constructor for host results, nil on failure
	err :: proc(vm_ptr: rawptr, payload: RevoValue) -> RevoValue ---

	/// whether the value is an `{:ok, ...}` table
	is_ok :: proc(vm_ptr: rawptr, val: RevoValue) -> bool ---

	/// whether the value is an `{:err, ...}` table
	is_err :: proc(vm_ptr: rawptr, val: RevoValue) -> bool ---

	/// payload of an `{:ok, ...}` table; false otherwise
	ok_value :: proc(vm_ptr: rawptr, val: RevoValue, out: ^RevoValue) -> bool ---

	/// call a revo function from c, returns false on type/resource error (max 16 args)
	call :: proc(vm_ptr: rawptr, func: RevoValue, argc: u64, argv: ^RevoValue, out: ^RevoValue) -> bool ---

	/// last failed `revo_call` message; empty when the last call worked
	/// , valid until the next `revo_call` on the same vm
	call_last_error :: proc(vm_ptr: rawptr) -> cstring ---

	/// the name is borrowed, keep it static
	/// empty name when len is 0 (name may be null then)
	/// nil on null fn or allocation failure
	cfunc_new :: proc(vm_ptr: rawptr, fn_ptr: rawptr, name: cstring, name_len: c.size_t) -> RevoValue ---

	/// return pointer to interned string data (null on failure, valid until next GC sweep)
	string_data :: proc(vm_ptr: rawptr, id: u64) -> cstring ---

	/// return byte length of an interned string (0 on failure)
	string_length :: proc(vm_ptr: rawptr, id: u64) -> c.size_t ---

	/// wrap a raw ptr; caller owns it, gc ignores it
	/// , low 48 bits only. null in, null out: `revo_is_opaque` first
	opaque_new :: proc(ptr: rawptr) -> RevoValue ---

	/// unwrap; null when not opaque and when wrapping null
	opaque_ptr :: proc(val: RevoValue) -> rawptr ---

	/// owned handles! caller ptr in a gc cell + a per-handle metatable
	/// , cell frees at sweep, pointee never. nil on failure
	resource_new :: proc(vm_ptr: rawptr, ptr: rawptr) -> RevoValue ---

	/// unwrap through the vm; null unless resource. null-ptr cells
	/// unwrap null too, so `revo_is_resource` first when it matters
	resource_ptr :: proc(vm_ptr: rawptr, val: RevoValue) -> rawptr ---

	/// stick a metatable on a handle, nil clears; false otherwise
	/// , share one table per kind & you have named types
	resource_setmetatable :: proc(vm_ptr: rawptr, ud: RevoValue, mt: RevoValue) -> bool ---

	/// read the metatable back; false unless one attached. same
	/// table means same kind: that is your type check
	resource_getmetatable :: proc(vm_ptr: rawptr, ud: RevoValue, out: ^RevoValue) -> bool ---

	/// pin a value past gc; registry id, 0 on failure
	/// , nil pins to 0, 0 never valid, ids never reused
	ref :: proc(vm_ptr: rawptr, val: RevoValue) -> u64 ---

	/// release a pin once; noop on 0/unknown
	unref :: proc(vm_ptr: rawptr, ref_id: u64) ---

	/// read back a pin; nil on 0/unknown/released
	getref :: proc(vm_ptr: rawptr, ref_id: u64) -> RevoValue ---

	/// reads like host arity errors: `wants N args, got M`
	c_err_arity :: proc(vm_ptr: rawptr, got: u64, expected: u64) -> int ---

	/// `expected` is a c string, `got` renders through typeof
	c_err_type :: proc(vm_ptr: rawptr, arg: u64, expected: cstring, got: RevoValue) -> int ---

	/// `msg` borrowed for the call only, copied before return
	c_err_other :: proc(vm_ptr: rawptr, msg: cstring) -> int ---

	/// run `func(table)` once when swept, errors swallowed
	/// , leftovers at destroy; false unless table + function
	/// , keep `func` reachable; explicit free unregisters
	table_set_finalizer :: proc(vm_ptr: rawptr, table: RevoValue, func: RevoValue) -> bool ---

	/// drop a pending finalizer; true only when one was there
	table_remove_finalizer :: proc(vm_ptr: rawptr, table: RevoValue) -> bool ---
}

ErevoVM :: struct {}
ErevoProgram :: struct {}
ErevoValue :: RevoValue
ErevoType :: RevoType

@(default_calling_convention = "c", link_prefix = "revo_")
foreign lib {
	/// create a new vm instance, returns null on failure
	@(link_name = "erevo_vm_create")
	erevo_vm_create :: proc() -> ^ErevoVM ---

	/// destroy a vm instance (null-safe)
	@(link_name = "erevo_vm_destroy")
	erevo_vm_destroy :: proc(vm: ^ErevoVM) ---

	/// return last error message, empty string if none (null-safe)
	@(link_name = "erevo_vm_last_error")
	erevo_vm_last_error :: proc(vm: ^ErevoVM) -> cstring ---

	/// compile source code into a program, returns null on error (null-safe)
	@(link_name = "erevo_compile")
	erevo_compile :: proc(vm: ^ErevoVM, name: cstring, source: cstring) -> ^ErevoProgram ---

	/// destroy a compiled program (null-safe)
	@(link_name = "erevo_program_destroy")
	erevo_program_destroy :: proc(program: ^ErevoProgram) ---

	/// execute a compiled program, writes result through out_value (both pointers optional)
	@(link_name = "erevo_run")
	erevo_run :: proc(vm: ^ErevoVM, program: ^ErevoProgram, out_value: ^RevoValue) -> bool ---

	/// compile, run, and free a program in one step (null-safe, out_value optional)
	@(link_name = "erevo_eval")
	erevo_eval :: proc(vm: ^ErevoVM, name: cstring, source: cstring, out_value: ^RevoValue) -> bool ---
}
