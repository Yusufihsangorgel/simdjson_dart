# Engineering rules

Core-Version: 1

Before changing this package, read this file, docs/engineering/package.md and docs/engineering/debt.json. These rules apply to every contributor. MUST and MUST_NOT are requirements. A SHOULD departure needs a recorded reason and review. Package rules supply concrete boundaries and contracts. An unresolved conflict blocks the affected edit. Existing defects are debt, not examples to copy.

1. Architecture and scale. MUST preserve the recorded library structure, dependency boundaries and public contracts. A function package may remain functions. A small library may remain one file or use parts. Do not add layers, interfaces or directories merely to match an architectural label. A structural repair needs evidence, a bounded purpose, compatibility checks and updated package rules.

2. Public API. MUST treat lib/src as implementation by convention, not as enforced privacy. Use the package's recorded public entry libraries. Keep implementation helpers out of exports. Extend existing show lists deliberately. In a library with parts or definitions in its entry file, use library-private names for helpers. Preserve deliberate cross-file helpers without exporting them. Do not remove an existing public name as incidental cleanup. Review transitive exports and public members as well as top-level declarations. Consumer examples use public entries; direct internal imports in tests follow the package-specific rule. Never import another package's src implementation.

3. Dependencies. MUST preserve the recorded direction, platform boundaries and runtime dependency limits. Keep policy independent of concrete adapters where that boundary already exists. Use existing interfaces or supplied functions at existing extension points. MUST_NOT introduce or enlarge an import cycle, reverse a protected dependency, or move an example dependency into runtime code. Existing cycles remain named debt until repaired. Parts belong to one library and are not separate dependency layers.

4. Responsibility and substitution. MUST keep each changed unit focused on one coherent responsibility. Reuse an existing implementation instead of copying business logic, validation or resource handling. Extract a small private helper when separate responsibilities change independently. Do not expose helpers or add speculative abstractions to satisfy a size limit. Implementations of an existing contract preserve its inputs, outputs, errors, ordering and ownership. Do not force unrelated clients to depend on new methods.

5. Errors. MUST preserve the package's error contract, including exception types, documented messages, null results, no-throw parsing, report findings, stream errors and synchronous versus asynchronous delivery. Keep debug assertions and release validation consistent with that contract. Translate infrastructure failures only at the existing boundary and retain cause or stack information where supported. Do not silently swallow errors. Broad catches require the documented recovery, reporting or cleanup contract and a test. Contract changes require compatibility review, tests and documentation.

6. State and ownership. MUST_NOT add mutable top-level or static state. A final reference can still hold mutable data. Keep new state within its owning instance, operation or stream. Existing shared-state exceptions must have exact locations, a purpose, lifecycle rules and evidence in the package rules; other existing shared state enters the debt protocol. Do not expand an exception. Release listeners, timers, handles and owned resources on success and failure. Never dispose a resource supplied by a caller unless the public contract transfers ownership.

7. Native and platform code. When applicable, MUST keep native declarations, calls, allocation helpers and build hooks within the package's recorded native boundary. Reuse its allocation and matching release paths, validate values before narrowing, and preserve disposal and buffer-lifetime contracts. Changed native entry points contain native failures at the boundary. Pure code stays free of native or platform dependencies. Preserve separate platform entry libraries and matching conditional implementations. A package without native code needs no native layer.

8. Tests and checks. Every behaviour change MUST include a test in the same change. A bug fix starts with a regression that fails on the previous implementation when reproducible. Test observable results, error paths and relevant ownership or platform behaviour. Prefer the public API unless a package rule permits an internal test. Run the package's recorded acceptance and CI commands, including required examples and platform jobs. Do not weaken assertions, analysis settings or required checks to obtain a pass. Record commands and exit codes; an unavailable check remains unverified. Update affected API documentation and the changelog.

9. Code hygiene. MUST_NOT add dead branches, unused helpers, commented-out implementations, temporary probes or unexplained suppressions. Remove dead code encountered within the change scope after checking compatibility and platform use. A TODO must link to an existing tracked issue and state its removal condition. A TODO or debt record never authorizes unfinished code in the current change.

10. Debt. Define the scope before editing: changed behaviour, affected symbols, required direct collaborators and their tests. Close small existing debt encountered in that scope in the same change, with verification. Record larger or out-of-scope findings in docs/engineering/debt.json with evidence, a proposed fix and closure criteria. Do not grow the task recursively. If safe delivery depends on a larger repair, complete that repair first or stop the affected change. MUST_NOT introduce debt, even when other debt is removed. A newly discovered old defect needs evidence that it predates the change. Recording an item is not closing it.

Review before completion:
- The change fits the recorded architecture and intentional public API.
- Dependencies, errors, ownership and applicable platform contracts are preserved.
- Behaviour changes have meaningful tests and required checks have recorded results.
- Scoped small debt is closed; other findings are tracked; no new debt is introduced.
- Documentation, evidence and the debt register match the final change.
- Publication checks pass for added paths, text and commit metadata.
