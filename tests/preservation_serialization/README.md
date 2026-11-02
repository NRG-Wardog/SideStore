# Preservation transaction serialization

`generate_fixture.py` extracts the **actual production** process-wide lane from
`PipelineRunner.swift`, unchanged, plus the exact `checkTransactionAdmission` closure, and appends inert async transaction cases.
The fixture also extracts the actual common-entry `performOperation` prefix,
including its real admission forwarding call. An inert pipeline suspends at the
native boundary; removing a cancelled per-app Progress from the registry must
still block dispatch. This is not a full UIKit/CoreData pipeline execution.
`test_contract.py` guards integration at the common direct/batch entry, ownership
through durable result accounting, all-operation coverage, no nested entry, and
the existing nonhost-taskgroup drain before host operations.

Run source checks and generate:

```sh
python3 tests/preservation_serialization/test_contract.py --repo .
python3 tests/preservation_serialization/generate_fixture.py --repo . --out /tmp/serialization
```

On a native Swift toolchain:

```sh
swiftc -parse-as-library /tmp/serialization/preservation-serialization.swift -o /tmp/serialization/cases
/tmp/serialization/cases
```

Cases cover overlapping transactions across awaited snapshot/mutation/readback,
FIFO, group/per-operation Progress cancellation after grant before mutation,
cancellation before registration, queued cancellation, grant/cancellation
races, expired admission before snapshot, stale-owner release and error release.
The source guard checks host-last scheduling; the native fixture does not claim
to execute the UIKit/CoreData runner, signing, device transport or an install.
The lane excludes only competing operations in this process, not external device
writers; preservation still requires fresh exact inventory/readback validation.
