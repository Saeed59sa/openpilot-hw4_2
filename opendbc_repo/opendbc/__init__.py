"""Lightweight placeholder for the upstream ``opendbc`` package."""
from __future__ import annotations

import importlib.abc
import importlib.machinery
import importlib.util
import sys
import types
from typing import Optional

_PLACEHOLDER_MSG = (
    "The real 'opendbc' package is not bundled with this training copy of "
    "openpilot. Replace 'opendbc_repo' with an upstream checkout to "
    "restore full functionality."
)


def __getattr__(name: str) -> None:
  raise ModuleNotFoundError(_PLACEHOLDER_MSG)


class _StubLoader(importlib.abc.Loader):
  """Loads placeholder submodules that raise informative errors."""

  def create_module(self, spec: importlib.machinery.ModuleSpec) -> types.ModuleType:
    module = types.ModuleType(spec.name)
    module.__file__ = __file__
    module.__package__ = spec.name
    module.__all__ = ()

    def _missing_attr(_: str) -> None:
      raise ModuleNotFoundError(_PLACEHOLDER_MSG)

    module.__getattr__ = _missing_attr  # type: ignore[attr-defined]
    module.__doc__ = _PLACEHOLDER_MSG
    module.__path__ = []  # type: ignore[attr-defined]
    return module

  def exec_module(self, module: types.ModuleType) -> None:
    # Nothing else to do once the placeholder module is created.
    return None


class _StubFinder(importlib.abc.MetaPathFinder):
  def find_spec(
      self,
      fullname: str,
      path: Optional[list[str]],
      target: Optional[types.ModuleType] = None,
  ) -> Optional[importlib.machinery.ModuleSpec]:
    if fullname == __name__:
      return None
    if fullname.startswith(__name__ + "."):
      return importlib.util.spec_from_loader(
          fullname,
          _StubLoader(),
          origin="missing opendbc placeholder",
          is_package=True,
      )
    return None


sys.meta_path.append(_StubFinder())

__all__: tuple[str, ...] = ()
__doc__ = _PLACEHOLDER_MSG
