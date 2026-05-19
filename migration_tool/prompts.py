"""Interactive prompter for the SageMaker Migration Tool first-run config.

Drives the first-run prompt sequence described in design.md
("Config Loader") and the acceptance criteria of Requirements 2.1,
2.6, 2.7, 2.8, and 2.9. The prompter never calls AWS APIs, never
spawns a subprocess, and never imports ``boto3``; it simply reads from
``input_func`` and writes to ``output_func`` (defaulting to
``builtins.input`` and :func:`print`).

Each accepted value is persisted via :meth:`ConfigLoader.set` BEFORE
the next prompt is shown, so a ``SIGKILL`` or ``Ctrl-C`` mid-flow
leaves prior accepted values on disk. This matches what
Requirements 2.2 and 2.6 jointly imply: a partial first run can be
resumed, and a step that demands a missing value can halt-and-prompt
without losing any of its predecessors. Values already populated in
the Config_File are skipped on re-entry (Requirement 2.3), so calling
:meth:`Prompter.prompt_first_run` a second time on a fully-populated
config is a no-op.

The module re-uses the validators in :mod:`migration_tool.config`
(``validate_repo_provider``, ``validate_repo_url``,
``validate_aws_region``, ``validate_account_id``) so the prompter and
the on-disk schema cannot drift apart.

Validates: Requirements 2.1, 2.6, 2.7, 2.8, 2.9.
"""

from __future__ import annotations

import builtins
from typing import Any, Callable, Optional

from migration_tool.config import (
    ConfigLoader,
    validate_account_id,
    validate_aws_region,
    validate_repo_provider,
    validate_repo_url,
)
from migration_tool.errors import ConfigError

__all__ = ["Prompter"]


# Mirror the closed Repo_Provider tuple from migration_tool.config so
# the prompter can render the indexed select menu without reaching into
# the private ``_REPO_PROVIDERS`` name. Keeping a local copy is
# intentional: a future change to the tuple in config.py is a deliberate
# decision that should require an equally deliberate update here.
_REPO_PROVIDERS: tuple[str, ...] = (
    "codecommit",
    "github",
    "github-enterprise-server",
    "gitlab",
    "gitlab-self-managed",
    "bitbucket",
)

# Permissive prefix check for the IAM Identity Center instance ARN
# (Requirement 2.1, ``identity_center_instance_arn``). The prompter
# only enforces the leading ``arn:aws:sso:::instance/`` segment and a
# non-empty suffix; tighter validation against the actual ARN format
# (e.g., the ssoins-XXXX shape) is intentionally deferred to the AWS
# CLI in step scripts where a real account is available.
_IDC_ARN_PREFIX = "arn:aws:sso:::instance/"


class Prompter:
    """Drive the first-run interactive prompt sequence.

    The prompter is constructed with a :class:`ConfigLoader` that owns
    the on-disk Config_File, plus two pluggable I/O callables. Tests
    inject stub callables so the prompter can be exercised without a
    TTY; production code accepts the defaults (``builtins.input`` and
    :func:`print`).

    Parameters
    ----------
    config:
        The :class:`ConfigLoader` whose ``set`` method receives every
        accepted value. Each ``set`` call writes the Config_File to
        disk before the next prompt is shown.
    input_func:
        Callable used in place of :func:`input`. Must accept a single
        ``str`` argument (the prompt cue) and return the user's
        response as a ``str``.
    output_func:
        Callable used in place of :func:`print`. Must accept a single
        ``str`` argument and return ``None``.
    """

    def __init__(
        self,
        config: ConfigLoader,
        *,
        input_func: Optional[Callable[[str], str]] = None,
        output_func: Optional[Callable[[str], None]] = None,
    ) -> None:
        self._config = config
        self._input: Callable[[str], str] = (
            input_func if input_func is not None else builtins.input
        )
        self._output: Callable[[str], None] = (
            output_func if output_func is not None else print
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def prompt_first_run(self) -> None:
        """Run the full first-run prompt sequence in canonical order.

        Each accepted value is persisted via ``config.set`` BEFORE the
        next prompt is shown. Keys whose Config_File value is already
        non-empty are skipped (Requirement 2.3), which makes
        re-entering the flow after a partial first run safe and makes
        a second call against a fully-populated config a no-op.

        Order (matching Requirement 2.1):

        1.  ``repo_provider`` — closed-set select.
        2.  ``repo_url`` — conditional, skipped when the resolved
            provider is ``codecommit``; validated against the
            provider-specific regex (Requirement 2.8).
        3.  ``aws_region`` — Requirement 2.10.
        4.  ``source_account_id`` — Requirement 2.11.
        5.  ``identity_center_instance_arn`` — permissive prefix
            check.
        6.  ``identity_center_identity_store_id`` — non-empty.
        7.  ``smus_domain_name`` — non-empty (collected before
            ``repo_name`` so the codecommit default is available).
        8.  ``admin_project_name`` — non-empty.
        9.  ``mwaa_environment_name`` — non-empty.
        10. ``source_s3_inclusion_list`` — comma-separated list of
            bucket names; persisted as a JSON array.
        11. ``mwaa_dag_bucket_name`` — non-empty.
        12. ``repo_name`` — conditional on
            ``repo_provider == "codecommit"`` (Requirement 2.9);
            default ``<smus_domain_name>-migration``.
        """

        # 1. repo_provider
        self._prompt_repo_provider()

        # The resolved provider drives the conditional URL prompt and
        # the conditional repo_name prompt. ``_safe_get`` returns
        # ``None`` if the value is somehow still missing (e.g., a
        # corrupted Config_File), but the prompt above guarantees a
        # value on the happy path.
        provider = self._safe_get("repo_provider")

        # 2. (conditional) repo_url — skipped for codecommit per
        # Requirement 2.9.
        if provider != "codecommit":
            self._prompt_repo_url(provider)

        # 3-9. Plain string prompts in canonical order. ``smus_domain_name``
        # is collected here (before ``repo_name``) so the codecommit
        # default ``<smus_domain_name>-migration`` is available when
        # the codecommit branch finally asks for ``repo_name`` below.
        self._prompt_aws_region()
        self._prompt_account_id()
        self._prompt_identity_center_instance_arn()
        self._prompt_identity_center_identity_store_id()
        self._prompt_smus_domain_name()
        self._prompt_admin_project_name()
        self._prompt_mwaa_environment_name()

        # 10. source_s3_inclusion_list
        self._prompt_s3_inclusion_list()

        # 11. mwaa_dag_bucket_name
        self._prompt_mwaa_dag_bucket_name()

        # 12. (conditional) repo_name — codecommit only. The default
        # depends on smus_domain_name, which was collected above.
        if provider == "codecommit":
            self._prompt_repo_name()

    def prompt_for_missing(self, keys: list[str]) -> None:
        """Re-run only the prompts for the supplied keys.

        Used by the orchestrator's mid-run halt-and-prompt path
        (Requirement 2.6). Each prompt handler honours the
        "already-set" check, so passing a key whose Config_File value
        is already non-empty is a no-op for that key. Unknown keys are
        silently skipped — the orchestrator may pass step-internal
        keys (for example ``smus_domain_id``) that this module does
        not know how to prompt for.
        """

        dispatch: dict[str, Callable[[], None]] = {
            "repo_provider": self._prompt_repo_provider,
            "repo_url": self._prompt_repo_url_via_dispatch,
            "repo_name": self._prompt_repo_name,
            "aws_region": self._prompt_aws_region,
            "source_account_id": self._prompt_account_id,
            "identity_center_instance_arn": (
                self._prompt_identity_center_instance_arn
            ),
            "identity_center_identity_store_id": (
                self._prompt_identity_center_identity_store_id
            ),
            "smus_domain_name": self._prompt_smus_domain_name,
            "admin_project_name": self._prompt_admin_project_name,
            "mwaa_environment_name": self._prompt_mwaa_environment_name,
            "source_s3_inclusion_list": self._prompt_s3_inclusion_list,
            "mwaa_dag_bucket_name": self._prompt_mwaa_dag_bucket_name,
        }
        for key in keys:
            handler = dispatch.get(key)
            if handler is None:
                # Unknown key — silently skip. The orchestrator may
                # pass step-internal keys (such as ``smus_domain_id``)
                # that have no first-run prompt.
                continue
            handler()

    # ------------------------------------------------------------------
    # Per-key prompt handlers
    # ------------------------------------------------------------------

    def _prompt_repo_provider(self) -> None:
        """Prompt for the closed-set ``repo_provider`` (Requirement 2.7).

        Prints the six options on separate lines, one per line, with a
        ``<index>. <token>`` shape, and accepts either the literal
        token or the 1-based index. Re-prompts on any other input.
        """

        if self._already_set("repo_provider"):
            return
        self._output("Select repo_provider:")
        for idx, name in enumerate(_REPO_PROVIDERS, start=1):
            self._output(f"  {idx}. {name}")
        while True:
            raw = self._input("> ").strip()
            # Accept either the literal token or the 1-based index.
            if raw.isdigit():
                index = int(raw)
                if 1 <= index <= len(_REPO_PROVIDERS):
                    value = _REPO_PROVIDERS[index - 1]
                    self._config.set("repo_provider", value)
                    return
            elif validate_repo_provider(raw):
                self._config.set("repo_provider", raw)
                return
            self._output(
                "Invalid repo_provider. Choose one of: "
                f"{', '.join(_REPO_PROVIDERS)} "
                f"(or 1-{len(_REPO_PROVIDERS)})."
            )

    def _prompt_repo_url(self, provider: Optional[str]) -> None:
        """Prompt for ``repo_url`` validated against ``provider``'s regex.

        Implements Requirement 2.8. ``provider`` is passed in so the
        validator picks the correct regex without re-reading the
        Config_File on every loop iteration.
        """

        if self._already_set("repo_url"):
            return
        if provider is None:
            # Defensive: ``prompt_first_run`` always collects
            # ``repo_provider`` first, but ``prompt_for_missing`` could
            # in principle be called with ``repo_url`` alone. Without a
            # provider there is no regex to validate against, so we
            # report and return rather than spin in an infinite
            # re-prompt loop.
            self._output(
                "Cannot prompt for repo_url: repo_provider is not set."
            )
            return
        self._output(f"Enter repo_url for provider '{provider}':")
        while True:
            value = self._input("> ").strip()
            if validate_repo_url(provider, value):
                self._config.set("repo_url", value)
                return
            self._output(
                f"Invalid repo_url for provider '{provider}'. Try again."
            )

    def _prompt_repo_url_via_dispatch(self) -> None:
        """Adapter used by ``prompt_for_missing`` to look up the provider."""

        self._prompt_repo_url(self._safe_get("repo_provider"))

    def _prompt_repo_name(self) -> None:
        """Prompt for the optional codecommit ``repo_name`` (Requirement 2.9).

        Default value is ``<smus_domain_name>-migration``. Empty input
        accepts the default; any non-empty input is taken as-is. The
        prompter does not validate the resulting name against
        CodeCommit's own naming rules; Step 1 surfaces any AWS-side
        error if the value is unacceptable.
        """

        if self._already_set("repo_name"):
            return
        # The default depends on ``smus_domain_name``. In the canonical
        # ``prompt_first_run`` flow that key is collected earlier, so
        # ``_safe_get`` returns the user's domain name. When invoked
        # via ``prompt_for_missing`` with only ``repo_name`` and no
        # domain name on disk, we fall back to a literal placeholder
        # rather than fabricating a real name.
        domain = self._safe_get("smus_domain_name")
        if domain:
            default = f"{domain}-migration"
        else:
            default = "<smus_domain_name>-migration"
        self._output(f"Enter repo_name [{default}]:")
        value = self._input("> ").strip()
        if value == "":
            value = default
        self._config.set("repo_name", value)

    def _prompt_aws_region(self) -> None:
        """Prompt for ``aws_region`` (Requirement 2.10)."""

        if self._already_set("aws_region"):
            return
        self._output("Enter aws_region (e.g. us-east-1):")
        while True:
            value = self._input("> ").strip()
            if validate_aws_region(value):
                self._config.set("aws_region", value)
                return
            self._output(
                "Invalid aws_region. Expected shape <aa>-<word>-<digit> "
                "(for example us-east-1)."
            )

    def _prompt_account_id(self) -> None:
        """Prompt for ``source_account_id`` (Requirement 2.11)."""

        if self._already_set("source_account_id"):
            return
        self._output("Enter source_account_id (12 digits):")
        while True:
            value = self._input("> ").strip()
            if validate_account_id(value):
                self._config.set("source_account_id", value)
                return
            self._output(
                "Invalid source_account_id. Must be exactly 12 digits."
            )

    def _prompt_identity_center_instance_arn(self) -> None:
        """Prompt for ``identity_center_instance_arn`` (permissive prefix)."""

        if self._already_set("identity_center_instance_arn"):
            return
        self._output(
            "Enter identity_center_instance_arn "
            "(arn:aws:sso:::instance/...):"
        )
        while True:
            value = self._input("> ").strip()
            if (
                value.startswith(_IDC_ARN_PREFIX)
                and len(value) > len(_IDC_ARN_PREFIX)
            ):
                self._config.set("identity_center_instance_arn", value)
                return
            self._output(
                "Invalid identity_center_instance_arn. Must start with "
                f"'{_IDC_ARN_PREFIX}' and include a non-empty instance "
                "suffix."
            )

    def _prompt_identity_center_identity_store_id(self) -> None:
        """Prompt for ``identity_center_identity_store_id`` (non-empty)."""

        self._prompt_nonempty("identity_center_identity_store_id")

    def _prompt_smus_domain_name(self) -> None:
        """Prompt for ``smus_domain_name`` (non-empty)."""

        self._prompt_nonempty("smus_domain_name")

    def _prompt_admin_project_name(self) -> None:
        """Prompt for ``admin_project_name`` (non-empty)."""

        self._prompt_nonempty("admin_project_name")

    def _prompt_mwaa_environment_name(self) -> None:
        """Prompt for ``mwaa_environment_name`` (non-empty)."""

        self._prompt_nonempty("mwaa_environment_name")

    def _prompt_mwaa_dag_bucket_name(self) -> None:
        """Prompt for ``mwaa_dag_bucket_name`` (non-empty)."""

        self._prompt_nonempty("mwaa_dag_bucket_name")

    def _prompt_s3_inclusion_list(self) -> None:
        """Prompt for ``source_s3_inclusion_list`` (comma-separated).

        The raw input is split on commas, each token is stripped of
        leading/trailing whitespace, empty tokens are dropped, and the
        cleaned result is persisted as a JSON array of strings (the
        Config_File schema declares the field as
        ``array of string``). Re-prompts when the cleaned list is
        empty.
        """

        if self._already_set("source_s3_inclusion_list"):
            return
        self._output(
            "Enter source_s3_inclusion_list "
            "(comma-separated bucket names):"
        )
        while True:
            raw = self._input("> ")
            tokens = [token.strip() for token in raw.split(",")]
            cleaned = [token for token in tokens if token]
            if cleaned:
                # Persisted as a Python list, which the ConfigLoader
                # serialises to a JSON array on save.
                self._config.set("source_s3_inclusion_list", cleaned)
                return
            self._output(
                "source_s3_inclusion_list cannot be empty. Provide at "
                "least one bucket name."
            )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _prompt_nonempty(self, key: str) -> None:
        """Generic non-empty string prompt with re-prompt on blank input.

        Used for every plain-string key whose only validation is "must
        not be empty after stripping whitespace". Honours the
        already-set check, so a populated value is a no-op.
        """

        if self._already_set(key):
            return
        self._output(f"Enter {key}:")
        while True:
            value = self._input("> ").strip()
            if value:
                self._config.set(key, value)
                return
            self._output(f"{key} cannot be empty. Try again.")

    def _already_set(self, key: str) -> bool:
        """Return ``True`` iff the Config_File has a non-empty value for ``key``.

        ``ConfigLoader.get`` raises :class:`ConfigError` when the key
        is missing or empty (``None`` / ``""`` / ``[]``), so a
        successful return means the value is genuinely populated and
        the prompt for that key should be skipped (Requirement 2.3).
        """

        try:
            self._config.get(key)
        except ConfigError:
            return False
        return True

    def _safe_get(self, key: str) -> Optional[Any]:
        """Like :meth:`ConfigLoader.get` but returns ``None`` when missing.

        Used by the conditional branches in
        :meth:`prompt_first_run` and by the ``repo_url`` adapter in
        :meth:`prompt_for_missing` so they can branch on a value
        without wrapping every access in a ``try`` / ``except``.
        """

        try:
            return self._config.get(key)
        except ConfigError:
            return None
