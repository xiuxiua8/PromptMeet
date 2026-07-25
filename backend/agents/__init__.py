__all__ = ["AgentProcessor"]


def __getattr__(name):
    if name == "AgentProcessor":
        from .agent_processor import AgentProcessor

        return AgentProcessor
    raise AttributeError(name)
