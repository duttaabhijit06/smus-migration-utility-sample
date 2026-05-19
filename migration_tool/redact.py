"""Secret redaction for the SageMaker Migration Tool run log.

This module implements Requirement 4.5: every command line and every
captured ``stdout`` / ``stderr`` block must have secret-shaped values
replaced with the literal string ``***REDACTED***`` before it reaches
disk. The redactor is exposed as a single pure function,
:func:`redact`, so it is fully deterministic and exhaustively
property-testable.

The redactor recognizes four overlapping patterns and applies them in
this order, so longer matches (the ``--flag value`` form) are processed
before the bare environment-variable form:

1. **Long-form CLI flag with a separate value.** Tokens of the form
   ``--<flag-name> <value>`` where ``<flag-name>`` matches any of the
   case-insensitive globs ``*token*``, ``*secret*``, ``*password*``,
   or ``*key*``. The whitespace between flag and value is one or more
   spaces or a tab; the value extends to the next whitespace boundary
   or end of line, and quoted values (``"..."`` or ``'...'``) are
   redacted in full.
2. **Long-form CLI flag with an ``=``-joined value.** Tokens of the
   form ``--<flag-name>=<value>`` (no whitespace) where ``<flag-name>``
   matches the same globs. Only the ``<value>`` portion is replaced;
   the ``--<flag>=`` prefix is preserved.
3. **Bare environment-variable substitutions.** ``$VARNAME`` or
   ``${VARNAME}`` where ``VARNAME`` matches the same globs. The whole
   ``$VARNAME`` / ``${VARNAME}`` token is replaced.
4. **AWS credential signatures (defense in depth).** Any standalone
   ``AKIA[A-Z0-9]{16}`` substring is replaced wholesale, and any
   ``aws_secret_access_key=<value>`` substring (case-insensitive on
   the key part) has its ``<value>`` replaced. Treating the value as
   a non-whitespace, non-``&`` run of characters covers both shell
   exports and URL query strings.

The module uses only Python's standard ``re`` library and does not
import from any other ``migration_tool`` module, so it is safe to
import from any layer of the orchestrator (logger, runner, CLI).

Validates: Requirement 4.5.
"""

from __future__ import annotations

import re

__all__ = ["redact"]


# The literal replacement string mandated by Requirement 4.5.
_REDACTION = "***REDACTED***"

# Case-insensitive translation of the globs ``*token*``, ``*secret*``,
# ``*password*``, ``*key*`` for CLI flag names. Flag names are allowed
# to contain ASCII letters, digits, underscores, and hyphens.
_FLAG_NAME = r"[A-Za-z0-9_-]*(?:token|secret|password|key)[A-Za-z0-9_-]*"

# Same translation for shell variable names. Variable names are allowed
# to contain ASCII letters, digits, and underscores (no hyphens).
_VAR_NAME = r"[A-Za-z0-9_]*(?:token|secret|password|key)[A-Za-z0-9_]*"

# Pattern 1: ``--<flag> <value>`` with one or more spaces or a tab
# between the flag and the value. The value is either a double-quoted
# run, a single-quoted run, or a non-whitespace run that extends to
# the next whitespace boundary or end of line.
_PATTERN_FLAG_SPACE_VALUE = re.compile(
    r"(--" + _FLAG_NAME + r")([ \t]+)"
    r"(\"[^\"]*\"|'[^']*'|\S+)",
    re.IGNORECASE,
)

# Pattern 2: ``--<flag>=<value>`` with no whitespace between flag and
# value. The value runs to the next whitespace boundary; an empty
# value is allowed (``--key=`` becomes ``--key=***REDACTED***``).
_PATTERN_FLAG_EQ_VALUE = re.compile(
    r"(--" + _FLAG_NAME + r"=)(\S*)",
    re.IGNORECASE,
)

# Pattern 3: ``$VARNAME`` or ``${VARNAME}`` env-var substitutions.
# Braces must be balanced (the optional ``{`` always pairs with a
# matching ``}``), so a stray ``${`` does not collapse into the bare
# ``$VARNAME`` form.
_PATTERN_ENV_VAR = re.compile(
    r"\$(?:\{" + _VAR_NAME + r"\}|" + _VAR_NAME + r")",
    re.IGNORECASE,
)

# Pattern 4a: AWS access-key-ID signature. Always uppercase by spec.
_PATTERN_AKIA = re.compile(r"AKIA[A-Z0-9]{16}")

# Pattern 4b: ``aws_secret_access_key=<value>``. Case-insensitive on
# the key, with the value treated as a non-whitespace, non-``&`` run
# so the same regex covers shell exports and URL query strings.
_PATTERN_AWS_SECRET = re.compile(
    r"(aws_secret_access_key=)([^\s&]*)",
    re.IGNORECASE,
)


def redact(line: str) -> str:
    """Return a redacted copy of ``line``.

    Every secret-shaped substring (per the four patterns documented at
    the module level) is replaced with the literal string
    ``***REDACTED***``. The function is pure: it performs no I/O, does
    not mutate its input, and produces deterministic output for any
    input.

    Validates: Requirement 4.5.
    """
    # Pattern 1: ``--<flag> <value>`` — keep the flag and the
    # separating whitespace, replace the value with the redaction.
    line = _PATTERN_FLAG_SPACE_VALUE.sub(r"\1\2" + _REDACTION, line)

    # Pattern 2: ``--<flag>=<value>`` — keep the ``--<flag>=`` prefix,
    # replace the value with the redaction.
    line = _PATTERN_FLAG_EQ_VALUE.sub(r"\1" + _REDACTION, line)

    # Pattern 3: ``$VARNAME`` / ``${VARNAME}`` — replace the entire
    # ``$``-prefixed token.
    line = _PATTERN_ENV_VAR.sub(_REDACTION, line)

    # Pattern 4a: bare ``AKIA...`` access-key-ID signatures.
    line = _PATTERN_AKIA.sub(_REDACTION, line)

    # Pattern 4b: ``aws_secret_access_key=<value>`` — keep the
    # ``aws_secret_access_key=`` prefix (case preserved as written),
    # replace the value.
    line = _PATTERN_AWS_SECRET.sub(r"\1" + _REDACTION, line)

    return line
