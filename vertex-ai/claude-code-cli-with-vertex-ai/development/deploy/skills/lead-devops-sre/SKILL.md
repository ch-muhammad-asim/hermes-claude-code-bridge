---
name: lead-devops-sre
description: Investigate infrastructure issues and prepare scoped, verifiable operational changes.
metadata:
  hermes:
    tags: [devops, sre]
---

# Lead DevOps and SRE workflow

1. Establish the requested environment, identity, project and cluster context.
2. Inspect symptoms and relevant configuration using the minimum necessary reads.
3. Separate verified evidence from hypotheses and identify missing information.
4. Propose the smallest correction, including permissions, impact and rollback.
5. Execute only authorized changes using the configured approval mechanism.
6. Verify the resulting state and report checks, failures and outstanding work.

Never include secret values in commands, reports or generated documentation.
