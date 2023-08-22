from __future__ import annotations

from typing import Iterable

from components.common.nitta_node import NittaNode

_SINGLE_BIND_DECISION_TAG = "SingleBindView"
_GROUP_BIND_DECISION_TAG = "GroupBindView"
_BIND_DECISION_TAGS = [_SINGLE_BIND_DECISION_TAG, _GROUP_BIND_DECISION_TAG]
_DATAFLOW_DECISION_TAGS = ["DataflowDecisionView"]


def nitta_node_to_df_dict(
    node: NittaNode,
    siblings: Iterable[NittaNode],
    example: str | None = None,
) -> dict:
    return dict(
        example=example,
        sid=node.sid,
        tag=node.decision_tag,
        old_score=node.score,
        is_terminal=node.is_terminal,
        **_extract_alternative_siblings_dict(node, siblings),
        **_extract_params_dict(node),
    )


def _extract_params_dict(node: NittaNode) -> dict:
    if node.decision_tag in _DATAFLOW_DECISION_TAGS + _BIND_DECISION_TAGS:
        assert isinstance(node.parameters, dict), "parameters must be a dict for Bind and Dataflow decisions"
        result = node.parameters.copy()
        if node.decision_tag in _DATAFLOW_DECISION_TAGS:
            result["pNotTransferableInputs"] = sum(result["pNotTransferableInputs"])
        elif node.decision_tag in _BIND_DECISION_TAGS:
            del result["tag"]
        return result

    if node.decision_tag == "RootView":
        return {}

    # only refactorings left, which have arbitrary decision tags
    return {"pRefactoringType": node.decision_tag}


def _extract_alternative_siblings_dict(node: NittaNode, siblings: Iterable[NittaNode]) -> dict:
    # this could be refactored to simply get a count per decision tag,
    # but backwards compatibility with old models will be broken
    result = {
        "alt_bindings": 0,
        "alt_group_bindings": 0,
        "alt_dataflows": 0,
        "alt_refactorings": 0,
    }

    for sibling in siblings:
        if sibling.sid == node.sid:
            continue
        if sibling.decision_tag == _SINGLE_BIND_DECISION_TAG:
            result["alt_bindings"] += 1
        elif sibling.decision_tag == _GROUP_BIND_DECISION_TAG:
            result["alt_group_bindings"] += 1
        elif sibling.decision_tag in _DATAFLOW_DECISION_TAGS:
            result["alt_dataflows"] += 1
        else:
            # refactorings have arbitrary decision tags
            result["alt_refactorings"] += 1

    return result
