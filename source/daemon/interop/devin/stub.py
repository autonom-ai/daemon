#!/usr/bin/python3
"""Shadow shim: Devin Desktop windows with a stale cached registry spawn this
path; redirect to the real Autonom ACP relay."""
import os
os.execv(
    "/home/cet/Repos/autonom/bin/autonom-acp",
    ["autonom-acp", "--config", "/home/cet/.config/autonom/config.yml"],
)
