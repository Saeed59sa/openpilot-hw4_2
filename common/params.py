from openpilot.common.params_pyx import Params, ParamKeyFlag, ParamKeyType, UnknownKeyName
assert Params
assert ParamKeyFlag
assert ParamKeyType
assert UnknownKeyName

if __name__ == "__main__":
  import sys

  params = Params()
  key = sys.argv[1]
  assert params.check_key(key), f"unknown param: {key}"

  if len(sys.argv) == 3:
    val = sys.argv[2]
    print(f"SET: {key} = {val}")
    params.put(key, val)
  elif len(sys.argv) == 2:
    print(f"GET: {key} = {params.get(key)}")

# BEGIN_REMOTE_ACCESS_PARAMS  # SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
# Remote Access params registry (multiple-tree compatible)
for _name, _ptype, _default in [
  ("EnableRemoteAccess", "bool",  b"0"),
  ("RemoteAccessLoginURL", "bytes", b""),
  ("RemoteAccessQRCode", "bytes", b""),
  ("RemoteAccessIP", "bytes", b""),
  ("RemoteAccessLastUpdated", "bytes", b""),
  ("RemoteAccessError", "bytes", b""),
]:
  keys_dict = globals().get('keys')
  if isinstance(keys_dict, dict) and _name not in keys_dict:
    keys_dict[_name] = (_ptype, _default)

  alt_keys = globals().get('_keys')
  if isinstance(alt_keys, dict) and _name not in alt_keys:
    alt_keys[_name] = (_ptype, _default)

  params_types = globals().get('_params_types')
  if isinstance(params_types, dict) and _name not in params_types:
    params_types[_name] = _ptype
    default_values = globals().get('_default_values')
    if isinstance(default_values, dict):
      default_values[_name] = _default
# END_REMOTE_ACCESS_PARAMS
