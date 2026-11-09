.PHONY: validate lint spec-drift

validate: lint
	python3 ci/validate_yaml.py config/gateway-spec.production.yaml
	python3 ci/validate_yaml.py config/gateway-spec.sandbox.yaml

lint:
	python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['config/gateway-spec.production.yaml','config/gateway-spec.sandbox.yaml']]"

# Requires an active Snowflake connection (snow CLI context or env credentials)
spec-drift:
	python3 ci/check_spec_drift.py --expected config/gateway-spec.production.yaml
