from geoserver_agent import GeoServerAgent


def test_agent_routes_workspace_listing():
    agent = GeoServerAgent()

    result = agent.route("List the GeoServer workspaces")

    assert result["action"] == "list_workspaces"
    assert "workspace" in result["summary"].lower()


def test_agent_falls_back_to_general_help():
    agent = GeoServerAgent()

    result = agent.route("Tell me a joke about Docker")

    assert result["action"] == "general_help"
    assert "docker" in result["summary"].lower()
