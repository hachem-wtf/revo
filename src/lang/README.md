# lang

the revo frontend: text in, bytecode out. the vm lives in
`../vm/`, the baselib in `../baselib/`, this dir is everything between

## pipeline

one file per stage, data flows down, never back up:

```ruby
source -> Lexer -> Parser -> expand -> semantic -> compiler -> bytecode
```

`pipeline.zig` drives it (`build` is the whole thing)

`pipeline/` holds its companions: `scope_wiring` (`@exports` wiring)
and `import_scan` (compile-time import extraction)

## files

- `ast.zig`: ast defs, tree walking, and printing
- `Lexer.zig`: tokenizer
- `Parser.zig`: `parseSource`, `parseSourceReport`, token to tree
- `macro_proc.zig`: `proc!` macros + `ProcEvaluator` trait (child-VM run is the default impl);
  `macro_common.zig` holds qualified-name/call rebuild bits
- `scope_graph.zig`: `ScopeId`/`DefId` graph + `transparent` kinds, populated alongside legacy scopes
- `semantic.zig`: name and type checking, owns `Failure`
- `compiler/`: compiling to bytecode; `types.zig` is where all the types are at
  plus `evalTypeExpr` and the `CheckCtx` interface every scope implements
- `ir/`: `IrInst` (`tmp_index` for dce) plus the optimization passes, `opt.zig` runs em all
  (`optimize` fuses fold→dce→peephole, same order)
- `type_syntax.zig`: text-only type serialization/deserialiization
- `import_types.zig`: public type surface of a module
- `diagnostic.zig`: reports: parts, spans, severities, render
- `pipeline/`: build orchestration stuff
- `Workspace.zig` + `workspace/`: incremental IDE state (hover, completions, symbols, diagnostics);
  the repl, lsp, and cli all build through it. `workspace/query.zig` tracks
  content hashes + revision (salsa-style inputs, taking over from version+opts)
- `Project.zig`:
  `lib.json` / `exe.json` detection
  (only for now, later itll actually manage build & lsp features and such)
- `docgen.zig`: doc extraction and rendering
- `test_helpers.zig`: test helpers; `lang_tests.zig`: the language suite;
  `ir/tests.zig`: the optimizer suite
- `root.zig`: facade for outsiders, re-exports only

## import rules

siblings import each other directly by relative path

nothing inside `lang/` imports `root.zig`
, and nothing reaches back through the `revo` module.
    `root.zig` exists for `repl.zig`, `main.zig`, `vm/`, `std/`, and friends

zig does allow it and its fine, its just cleaner this way

type code takes `types.CheckCtx`, never `anytype`

the four scopes (`Compiler`, `SemanticChecker`, `ModuleCtx`, `BareCtx`)
each have a one-line `check()`;\
    add an interface method and all four fail to build until they implement it

## how to add things

new syntax: `Lexer.zig` (tokens) -> `Parser.zig` (tree) -> `ast.zig`
    (node kinds) -> `macro_proc.zig` if it expands, `compiler/` if it compiles

new builtin: `../baselib/base.rv` table plus zig impl (see `../baselib/`)
    docs and runtime stay in sync that way

new type behavior: `compiler/types.zig` inference, `type_syntax.zig` only if the text spelling changes

new check: `semantic.zig`, errors accumulate as report parts and the single `Failure` carries them out.
error codes are kebab slugs on the report, add one when the message alone is not greppable

new ide feature: `workspace/`, one file per provider. `Workspace`
re-exports each provider as a member alias so call sites keep method
syntax while implementations stay in focused files

## tests

unit tests go inline next to the code
end-to-end coverage lives in `lang_tests.zig` via the `test_helpers.zig` helpers
