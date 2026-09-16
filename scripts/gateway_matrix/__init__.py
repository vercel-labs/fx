"""Live compatibility matrix for fx against Vercel AI Gateway models.

Drives a built ``fx`` binary through multi-turn ``fx ask`` conversations while a
loopback proxy records every Gateway request and response. Used to answer
questions like "which routes reject fx's prompt layout?" with wire evidence.
See README.md in this directory.
"""
