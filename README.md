# Zorth

A compatible Porth implementation, but in ~~$300~~ Zig.

My goal for this is to have feature parity with the self-hosted Porth
implementation, but without the required bootstrapping. You could of course
still bootstrap Porth using the Zig-built executable.

Currently, the tests do not all pass. There is a subtle mistake I'm making that
causes rule 110 to output differently depending on whether the code is being
simulated or compiled then run.

