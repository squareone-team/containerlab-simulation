#!/usr/bin/env python3
"""Provision the ESI lab into the Zabbix frontend through the official API."""

import json
import os
import sys
import time
import urllib.error
import urllib.request


API_URL = os.environ.get("ZABBIX_API_URL", "http://127.0.0.1:8080/api_jsonrpc.php")
API_USER = os.environ.get("ZABBIX_API_USER", "Admin")
API_PASSWORD = os.environ.get("ZABBIX_API_PASSWORD", "zabbix")
SNMP_COMMUNITY = os.environ.get("ZABBIX_SNMP_COMMUNITY", "esi-read")

FABRIC_GROUP = "ESI Datacenter/Fabric"
SPINE_GROUP = "ESI Datacenter/Spines"
LEAF_GROUP = "ESI Datacenter/Leaves"
DASHBOARD_NAME = "ESI Fabric NOC"
MAP_NAME = "ESI Datacenter Fabric"

TEMPLATE_CANDIDATES = (
    "Linux by SNMP",
    "Generic by SNMP",
    "ICMP Ping",
    "Template Module Generic SNMP",
    "Template Module Interfaces SNMP",
)

NODES = [
    {
        "name": "spine-01",
        "ip": "10.1.0.1",
        "role": "spine",
        "asn": "65000",
        "x": 440,
        "y": 80,
        "peers": [
            "10.0.0.1",
            "10.0.0.3",
            "10.0.0.5",
            "10.0.0.7",
            "10.0.0.9",
            "10.0.0.11",
            "10.0.0.13",
            "10.0.0.15",
            "10.0.0.17",
            "10.0.0.19",
        ],
    },
    {
        "name": "spine-02",
        "ip": "10.1.0.2",
        "role": "spine",
        "asn": "65000",
        "x": 980,
        "y": 80,
        "peers": [
            "10.0.1.1",
            "10.0.1.3",
            "10.0.1.5",
            "10.0.1.7",
            "10.0.1.9",
            "10.0.1.11",
            "10.0.1.13",
            "10.0.1.15",
            "10.0.1.17",
            "10.0.1.19",
        ],
    },
    {
        "name": "leaf-01",
        "ip": "10.1.0.11",
        "role": "leaf",
        "asn": "65001",
        "pod": "border-student",
        "x": 80,
        "y": 340,
        "peers": ["10.0.0.0", "10.0.1.0"],
    },
    {
        "name": "leaf-02",
        "ip": "10.1.0.12",
        "role": "leaf",
        "asn": "65001",
        "pod": "border-student",
        "x": 220,
        "y": 520,
        "peers": ["10.0.0.2", "10.0.1.2"],
    },
    {
        "name": "leaf-03",
        "ip": "10.1.0.13",
        "role": "leaf",
        "asn": "65002",
        "pod": "admin-services",
        "x": 360,
        "y": 340,
        "peers": ["10.0.0.4", "10.0.1.4"],
    },
    {
        "name": "leaf-04",
        "ip": "10.1.0.14",
        "role": "leaf",
        "asn": "65002",
        "pod": "admin-services",
        "x": 500,
        "y": 520,
        "peers": ["10.0.0.6", "10.0.1.6"],
    },
    {
        "name": "leaf-05",
        "ip": "10.1.0.15",
        "role": "leaf",
        "asn": "65003",
        "pod": "hpc",
        "x": 640,
        "y": 340,
        "peers": ["10.0.0.8", "10.0.1.8"],
    },
    {
        "name": "leaf-06",
        "ip": "10.1.0.16",
        "role": "leaf",
        "asn": "65003",
        "pod": "hpc",
        "x": 780,
        "y": 520,
        "peers": ["10.0.0.10", "10.0.1.10"],
    },
    {
        "name": "leaf-07",
        "ip": "10.1.0.17",
        "role": "leaf",
        "asn": "65004",
        "pod": "storage",
        "x": 920,
        "y": 340,
        "peers": ["10.0.0.12", "10.0.1.12"],
    },
    {
        "name": "leaf-08",
        "ip": "10.1.0.18",
        "role": "leaf",
        "asn": "65004",
        "pod": "storage",
        "x": 1060,
        "y": 520,
        "peers": ["10.0.0.14", "10.0.1.14"],
    },
    {
        "name": "leaf-09",
        "ip": "10.1.0.19",
        "role": "leaf",
        "asn": "65005",
        "pod": "student-access",
        "x": 1200,
        "y": 340,
        "peers": ["10.0.0.16", "10.0.1.16"],
    },
    {
        "name": "leaf-10",
        "ip": "10.1.0.20",
        "role": "leaf",
        "asn": "65005",
        "pod": "student-access",
        "x": 1340,
        "y": 520,
        "peers": ["10.0.0.18", "10.0.1.18"],
    },
]

SPINE_LINK_PEERS = {
    ("spine-01", "leaf-01"): "10.0.0.1",
    ("spine-01", "leaf-02"): "10.0.0.3",
    ("spine-01", "leaf-03"): "10.0.0.5",
    ("spine-01", "leaf-04"): "10.0.0.7",
    ("spine-01", "leaf-05"): "10.0.0.9",
    ("spine-01", "leaf-06"): "10.0.0.11",
    ("spine-01", "leaf-07"): "10.0.0.13",
    ("spine-01", "leaf-08"): "10.0.0.15",
    ("spine-01", "leaf-09"): "10.0.0.17",
    ("spine-01", "leaf-10"): "10.0.0.19",
    ("spine-02", "leaf-01"): "10.0.1.1",
    ("spine-02", "leaf-02"): "10.0.1.3",
    ("spine-02", "leaf-03"): "10.0.1.5",
    ("spine-02", "leaf-04"): "10.0.1.7",
    ("spine-02", "leaf-05"): "10.0.1.9",
    ("spine-02", "leaf-06"): "10.0.1.11",
    ("spine-02", "leaf-07"): "10.0.1.13",
    ("spine-02", "leaf-08"): "10.0.1.15",
    ("spine-02", "leaf-09"): "10.0.1.17",
    ("spine-02", "leaf-10"): "10.0.1.19",
}

COLORS = [
    "2F80ED",
    "27AE60",
    "F2994A",
    "9B51E0",
    "EB5757",
    "56CCF2",
    "F2C94C",
    "6FCF97",
    "BB6BD9",
    "219653",
]


class ApiError(RuntimeError):
    pass


class ZabbixApi:
    def __init__(self, url):
        self.url = url
        self.auth = None
        self.next_id = 1

    def call(self, method, params=None, auth=True):
        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": self.next_id,
        }
        self.next_id += 1
        if auth and self.auth:
            payload["auth"] = self.auth

        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json-rpc"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise ApiError(f"{method}: {exc}") from exc

        if data.get("error"):
            error = data["error"]
            message = error.get("data") or error.get("message") or error
            raise ApiError(f"{method}: {message}")

        return data.get("result")

    def wait(self, timeout=120):
        deadline = time.time() + timeout
        last_error = ""
        while time.time() < deadline:
            try:
                version = self.call("apiinfo.version", auth=False)
                print(f"[zabbix-provision] API ready, version {version}")
                return version
            except ApiError as exc:
                last_error = str(exc)
                time.sleep(3)
        raise ApiError(f"API not ready after {timeout}s: {last_error}")

    def login(self):
        try:
            self.auth = self.call(
                "user.login",
                {"username": API_USER, "password": API_PASSWORD},
                auth=False,
            )
        except ApiError:
            self.auth = self.call(
                "user.login",
                {"user": API_USER, "password": API_PASSWORD},
                auth=False,
            )
        print(f"[zabbix-provision] logged in as {API_USER}")


def first_id(result, field):
    if not result:
        return None
    return result[0].get(field)


def ensure_group(api, name):
    result = api.call(
        "hostgroup.get",
        {"output": ["groupid", "name"], "filter": {"name": [name]}},
    )
    groupid = first_id(result, "groupid")
    if groupid:
        return groupid
    created = api.call("hostgroup.create", {"name": name})
    return created["groupids"][0]


def find_templates(api):
    for name in TEMPLATE_CANDIDATES:
        result = api.call(
            "template.get",
            {
                "output": ["templateid", "host", "name"],
                "filter": {"host": [name]},
            },
        )
        if not result:
            result = api.call(
                "template.get",
                {
                    "output": ["templateid", "host", "name"],
                    "filter": {"name": [name]},
                },
            )
        if result:
            template = result[0]
            print(f"[zabbix-provision] using template: {template['host']}")
            return {template["host"]: template["templateid"]}
    return {}


def ensure_macro(api, hostid, macro, value):
    result = api.call(
        "usermacro.get",
        {"output": ["hostmacroid", "macro"], "hostids": hostid, "filter": {"macro": macro}},
    )
    if result:
        api.call("usermacro.update", {"hostmacroid": result[0]["hostmacroid"], "value": value})
    else:
        api.call("usermacro.create", {"hostid": hostid, "macro": macro, "value": value})


def ensure_snmp_interface(api, hostid, ip):
    result = api.call(
        "hostinterface.get",
        {
            "output": ["interfaceid", "type", "main", "ip"],
            "hostids": hostid,
            "filter": {"type": 2, "main": 1},
        },
    )
    params = {
        "type": 2,
        "main": 1,
        "useip": 1,
        "ip": ip,
        "dns": "",
        "port": "161",
        "details": {
            "version": 2,
            "community": "{$SNMP_COMMUNITY}",
            "bulk": 1,
        },
    }
    if result:
        params["interfaceid"] = result[0]["interfaceid"]
        api.call("hostinterface.update", params)
        return result[0]["interfaceid"]

    params["hostid"] = hostid
    created = api.call("hostinterface.create", params)
    return created["interfaceids"][0]


def ensure_host(api, node, groupids, templateids):
    result = api.call(
        "host.get",
        {
            "output": ["hostid", "host", "name"],
            "selectGroups": ["groupid"],
            "selectParentTemplates": ["templateid"],
            "filter": {"host": [node["name"]]},
        },
    )

    groups = [{"groupid": groupid} for groupid in groupids]
    templates = [{"templateid": templateid} for templateid in templateids]
    tags = [
        {"tag": "lab", "value": "esi-datacenter"},
        {"tag": "role", "value": node["role"]},
        {"tag": "asn", "value": node["asn"]},
        {"tag": "pod", "value": node.get("pod", "core")},
    ]
    inventory = {
        "type": "FRR network node",
        "alias": node["name"],
        "os": "FRRouting on Alpine",
        "site_notes": f"Loopback {node['ip']} / AS {node['asn']}",
    }

    if result:
        host = result[0]
        hostid = host["hostid"]
        existing_groupids = {group["groupid"] for group in host.get("groups", [])}
        existing_templateids = {
            template["templateid"] for template in host.get("parentTemplates", [])
        }
        merged_groups = [{"groupid": groupid} for groupid in sorted(existing_groupids | set(groupids))]
        merged_templates = [
            {"templateid": templateid}
            for templateid in sorted(existing_templateids | set(templateids))
        ]
        update = {
            "hostid": hostid,
            "name": f"{node['name']} ({node['ip']})",
            "status": 0,
            "groups": merged_groups,
            "tags": tags,
            "inventory_mode": 0,
            "inventory": inventory,
        }
        if merged_templates:
            update["templates"] = merged_templates
        api.call("host.update", update)
    else:
        create = {
            "host": node["name"],
            "name": f"{node['name']} ({node['ip']})",
            "status": 0,
            "groups": groups,
            "interfaces": [
                {
                    "type": 2,
                    "main": 1,
                    "useip": 1,
                    "ip": node["ip"],
                    "dns": "",
                    "port": "161",
                    "details": {
                        "version": 2,
                        "community": "{$SNMP_COMMUNITY}",
                        "bulk": 1,
                    },
                }
            ],
            "tags": tags,
            "inventory_mode": 0,
            "inventory": inventory,
        }
        if templates:
            create["templates"] = templates
        created = api.call("host.create", create)
        hostid = created["hostids"][0]

    ensure_macro(api, hostid, "{$SNMP_COMMUNITY}", SNMP_COMMUNITY)
    interfaceid = ensure_snmp_interface(api, hostid, node["ip"])
    return hostid, interfaceid


def ensure_item(api, hostid, interfaceid, name, key, oid, value_type, delay="30s", units=""):
    trends = "30d" if value_type in (0, 3) else "0"
    result = api.call(
        "item.get",
        {"output": ["itemid"], "hostids": hostid, "filter": {"key_": key}},
    )
    params = {
        "name": name,
        "type": 20,
        "hostid": hostid,
        "interfaceid": interfaceid,
        "key_": key,
        "snmp_oid": oid,
        "value_type": value_type,
        "delay": delay,
        "history": "7d",
        "trends": trends,
        "status": 0,
    }
    if units:
        params["units"] = units

    if result:
        update = dict(params)
        update["itemid"] = result[0]["itemid"]
        update.pop("hostid", None)
        api.call("item.update", update)
        return result[0]["itemid"]

    created = api.call("item.create", params)
    return created["itemids"][0]


def ensure_trigger(api, hostid, description, expression, priority, recovery_expression=None):
    result = api.call(
        "trigger.get",
        {
            "output": ["triggerid", "description"],
            "hostids": hostid,
            "filter": {"description": description},
        },
    )
    params = {
        "description": description,
        "expression": expression,
        "priority": priority,
        "status": 0,
        "manual_close": 1,
    }
    if recovery_expression:
        params["recovery_mode"] = 1
        params["recovery_expression"] = recovery_expression

    if result:
        params["triggerid"] = result[0]["triggerid"]
        api.call("trigger.update", params)
        return result[0]["triggerid"]

    created = api.call("trigger.create", params)
    return created["triggerids"][0]


def ensure_graph(api, hostid, name, itemids):
    if not itemids:
        return None
    result = api.call(
        "graph.get",
        {"output": ["graphid", "name"], "hostids": hostid, "filter": {"name": name}},
    )
    if result:
        return result[0]["graphid"]

    gitems = []
    for index, itemid in enumerate(itemids):
        gitems.append(
            {
                "itemid": itemid,
                "color": COLORS[index % len(COLORS)],
                "drawtype": 0,
                "sortorder": index,
                "yaxisside": 0,
                "calc_fnc": 2,
                "type": 0,
            }
        )
    try:
        created = api.call(
            "graph.create",
            {
                "name": name,
                "width": 900,
                "height": 240,
                "show_triggers": 1,
                "ymin_type": 1,
                "ymax_type": 1,
                "yaxismin": 1,
                "yaxismax": 6,
                "gitems": gitems,
            },
        )
        return created["graphids"][0]
    except ApiError as exc:
        print(f"[zabbix-provision] graph skipped for hostid {hostid}: {exc}")
        return None


def choose_icon(api):
    result = api.call("image.get", {"output": ["imageid", "name", "imagetype"]})
    result = [image for image in result if str(image.get("imagetype")) == "1"]
    if not result:
        return None

    preferred = (
        "network switch",
        "switch",
        "router",
        "server",
    )
    for needle in preferred:
        for image in result:
            if needle in image["name"].lower():
                return image["imageid"]
    return result[0]["imageid"]


def ensure_map(api, hostids, link_triggerids):
    result = api.call(
        "map.get",
        {"output": ["sysmapid", "name"], "filter": {"name": [MAP_NAME]}},
    )
    if result:
        return result[0]["sysmapid"]

    iconid = choose_icon(api)
    if not iconid:
        print("[zabbix-provision] no imported image icons found; skipping map")
        return None

    selement_ids = {}
    selements = []
    for index, node in enumerate(NODES, start=1):
        selementid = str(index)
        selement_ids[node["name"]] = selementid
        selements.append(
            {
                "selementid": selementid,
                "elementtype": 0,
                "elements": [{"hostid": hostids[node["name"]]}],
                "iconid_off": iconid,
                "label": "{HOST.NAME}\n{HOST.CONN}",
                "x": node["x"],
                "y": node["y"],
            }
        )

    links = []
    for (spine, leaf), peer in SPINE_LINK_PEERS.items():
        link = {
            "selementid1": selement_ids[spine],
            "selementid2": selement_ids[leaf],
            "color": "2ECC71",
            "drawtype": 0,
        }
        triggerid = link_triggerids.get((spine, peer))
        if triggerid:
            link["linktriggers"] = [
                {
                    "triggerid": triggerid,
                    "color": "D2322D",
                    "drawtype": 2,
                }
            ]
        links.append(link)

    created = api.call(
        "map.create",
        {
            "name": MAP_NAME,
            "width": 1500,
            "height": 760,
            "label_format": 1,
            "label_type_host": 2,
            "selements": selements,
            "links": links,
        },
    )
    return created["sysmapids"][0]


def ensure_dashboard(api, mapid, fabric_groupid, graphids):
    result = api.call(
        "dashboard.get",
        {"output": ["dashboardid", "name"], "filter": {"name": [DASHBOARD_NAME]}},
    )
    if result:
        print(f"[zabbix-provision] dashboard already exists: {DASHBOARD_NAME}")
        return result[0]["dashboardid"]

    graph_widgets = []
    for index, (name, graphid) in enumerate(graphids[:6]):
        x = 0 if index % 2 == 0 else 12
        y = 0 + (index // 2) * 6
        graph_widgets.append(
            {
                "type": "graph",
                "name": name,
                "x": x,
                "y": y,
                "width": 12,
                "height": 6,
                "fields": [{"type": 6, "name": "graphid", "value": graphid}],
            }
        )

    overview_widgets = [
        {
            "type": "hostavail",
            "name": "Fabric Host Availability",
            "x": 0,
            "y": 0,
            "width": 8,
            "height": 5,
            "fields": [{"type": 2, "name": "groupids", "value": fabric_groupid}],
        },
        {
            "type": "problemsbysv",
            "name": "Problems By Severity",
            "x": 8,
            "y": 0,
            "width": 8,
            "height": 5,
            "fields": [{"type": 2, "name": "groupids", "value": fabric_groupid}],
        },
        {
            "type": "problems",
            "name": "Open Fabric Problems",
            "x": 16,
            "y": 0,
            "width": 8,
            "height": 5,
            "fields": [{"type": 2, "name": "groupids", "value": fabric_groupid}],
        },
    ]
    if mapid:
        overview_widgets.append(
            {
                "type": "map",
                "name": "Clos Fabric Topology",
                "x": 0,
                "y": 5,
                "width": 24,
                "height": 12,
                "fields": [{"type": 8, "name": "sysmapid", "value": mapid}],
            }
        )

    pages = [{"name": "Overview", "widgets": overview_widgets}]
    if graph_widgets:
        pages.append({"name": "BGP State", "widgets": graph_widgets})

    try:
        created = api.call(
            "dashboard.create",
            {
                "name": DASHBOARD_NAME,
                "display_period": 30,
                "auto_start": 1,
                "pages": pages,
            },
        )
        return created["dashboardids"][0]
    except ApiError as exc:
        print(f"[zabbix-provision] full dashboard failed: {exc}")
        created = api.call(
            "dashboard.create",
            {
                "name": DASHBOARD_NAME,
                "display_period": 30,
                "auto_start": 1,
                "pages": [
                    {
                        "name": "Overview",
                        "widgets": [
                            {
                                "type": "problems",
                                "name": "Open Fabric Problems",
                                "x": 0,
                                "y": 0,
                                "width": 24,
                                "height": 10,
                            },
                            {
                                "type": "hostavail",
                                "name": "Host Availability",
                                "x": 0,
                                "y": 10,
                                "width": 12,
                                "height": 6,
                            },
                        ],
                    }
                ],
            },
        )
        return created["dashboardids"][0]


def provision(api):
    fabric_groupid = ensure_group(api, FABRIC_GROUP)
    spine_groupid = ensure_group(api, SPINE_GROUP)
    leaf_groupid = ensure_group(api, LEAF_GROUP)

    templates = find_templates(api)
    templateids = list(templates.values())
    if not templateids:
        print("[zabbix-provision] no official SNMP templates found; custom checks still apply")

    hostids = {}
    graphids = []
    link_triggerids = {}

    for node in NODES:
        role_group = spine_groupid if node["role"] == "spine" else leaf_groupid
        hostid, interfaceid = ensure_host(api, node, [fabric_groupid, role_group], templateids)
        hostids[node["name"]] = hostid

        ensure_item(
            api,
            hostid,
            interfaceid,
            "SNMP system description",
            "esi.snmp.sysdescr",
            "1.3.6.1.2.1.1.1.0",
            4,
            "5m",
        )
        ensure_item(
            api,
            hostid,
            interfaceid,
            "SNMP system name",
            "esi.snmp.sysname",
            "1.3.6.1.2.1.1.5.0",
            1,
            "5m",
        )
        ensure_item(
            api,
            hostid,
            interfaceid,
            "SNMP system uptime",
            "esi.snmp.sysuptime",
            "1.3.6.1.2.1.1.3.0",
            3,
            "1m",
            "uptime",
        )
        ensure_trigger(
            api,
            hostid,
            "SNMP polling has no recent data on {HOST.NAME}",
            f"nodata(/{node['name']}/esi.snmp.sysuptime,5m)=1",
            4,
        )

        bgp_itemids = []
        for peer in node["peers"]:
            key = f"esi.bgp.peer.state[{peer}]"
            itemid = ensure_item(
                api,
                hostid,
                interfaceid,
                f"BGP peer {peer} state",
                key,
                f"1.3.6.1.2.1.15.3.1.2.{peer}",
                3,
                "30s",
            )
            bgp_itemids.append(itemid)
            triggerid = ensure_trigger(
                api,
                hostid,
                f"BGP peer {peer} is not established on {{HOST.NAME}}",
                f"last(/{node['name']}/{key})<>6",
                4,
                f"last(/{node['name']}/{key})=6",
            )
            link_triggerids[(node["name"], peer)] = triggerid

        graphid = ensure_graph(api, hostid, "BGP peer state", bgp_itemids)
        if graphid:
            graphids.append((f"{node['name']} BGP peer state", graphid))

    mapid = ensure_map(api, hostids, link_triggerids)
    dashboardid = ensure_dashboard(api, mapid, fabric_groupid, graphids)

    print(
        "[zabbix-provision] provisioned "
        f"{len(hostids)} hosts, {sum(len(node['peers']) for node in NODES)} BGP peer checks, "
        f"map={mapid or 'skipped'}, dashboard={dashboardid}"
    )


def main():
    api = ZabbixApi(API_URL)
    api.wait()
    api.login()
    provision(api)


if __name__ == "__main__":
    try:
        main()
    except ApiError as exc:
        print(f"[zabbix-provision] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
