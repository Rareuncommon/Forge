# ADR 0008 — Command schema generated from Swift types

- Status: accepted (M0)
- Date: 2026-09-23

## Context

SPEC §5.1: every command has a JSON Schema for params, a return type, errors, undo behaviour
and docs, "generated from Swift types — single source of truth". Swift has no runtime
reflection of `Codable` shape, and Swift macros would add a heavy `swift-syntax` build
dependency to every module.

## Decision

- A command is a Swift type conforming to `Command` with associated `Params: Decodable` and
  `Output: Codable`, static metadata (name, summary, discussion, category, undo behaviour,
  preconditions, errors, examples) and `run(params, &context)`.
- **Schemas are extracted by running the type's own `init(from:)` against a recording
  `Decoder`** (`ForgeCore/Schema.swift`). Every key requested becomes a property;
  `decodeIfPresent` marks it optional; nested types recurse; leaf types with custom decoding
  (units, points, enums) provide their schema via `JSONSchemaProviding`. The schema is
  therefore exactly what the decoder accepts — it cannot drift.
- Constraints: `init(from:)` must not validate (placeholders are zeros); semantic validation
  lives in `ValidatableParams.validate()`. Field docs live in `SchemaDocumented.fieldDocs`.
  Tests assert that every command's schema builds, every property is documented, and every
  example decodes and validates.
- JSON keys are snake_case via explicit `CodingKeys`; unit-bearing values are `Length`,
  `Angle`, `Point3` (number in document units, or `"25 mm"`, `"1 in"`, `"90 deg"`).
- Before decoding, the bus validates params structurally against the schema (unknown keys
  with "did you mean", missing keys, types, enums) so agents get precise errors.

## Consequences

- No code generation step and no macro dependency; adding a command is one Swift type.
- Dictionary-typed params cannot be described (their keys are data); use arrays of objects.
