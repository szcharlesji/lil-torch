"""Builds ../install.sh: the installer template with the agent embedded."""
import os

here = os.path.dirname(os.path.abspath(__file__))


def build():
    with open(os.path.join(here, "install.sh.in")) as handle:
        template = handle.read()
    with open(os.path.join(here, "liltorch_agent.py")) as handle:
        agent = handle.read().rstrip("\n")
    assert "LILTORCH_AGENT_SOURCE" not in agent
    return template.replace("@AGENT@", agent)


if __name__ == "__main__":
    path = os.path.join(here, "..", "install.sh")
    with open(path, "w") as handle:
        handle.write(build())
    os.chmod(path, 0o755)
    print("wrote", os.path.normpath(path))
