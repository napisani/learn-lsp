ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
NVIM ?= nvim
NPM ?= mise exec -- npm
FILE ?= README.md
DEV_HOME := $(ROOT)/.nvim-dev
DEV_ENV := XDG_CONFIG_HOME="$(DEV_HOME)/config" XDG_DATA_HOME="$(DEV_HOME)/data" XDG_STATE_HOME="$(DEV_HOME)/state" XDG_CACHE_HOME="$(DEV_HOME)/cache"
DEV_ROOT := --cmd "let g:vantage_nvim_root='$(ROOT)'"
PI_PROVIDER ?= openai
PI_MODEL ?= gpt-4o-mini
PI_TIMEOUT_MS ?= 300000
PI_ANNOTATION_TIMEOUT_MS ?= 300000
VANTAGE_DEBUG_LOG ?= /tmp/vantage-nvim.log
E2E_WAIT_MS ?= 120000
E2E_DIR := $(DEV_HOME)/e2e
E2E_TEMPLATE := $(ROOT)/examples/e2e-codebase
E2E_WORKSPACE := $(E2E_DIR)/workspace
TRACE_DIR := $(DEV_HOME)/trace
PI_DEV := --cmd "let g:vantage_dev_agent='pi'" --cmd "let g:vantage_pi_provider='$(PI_PROVIDER)'" --cmd "let g:vantage_pi_model='$(PI_MODEL)'" --cmd "let g:vantage_pi_timeout_ms=$(PI_TIMEOUT_MS)" --cmd "let g:vantage_pi_annotation_timeout_ms=$(PI_ANNOTATION_TIMEOUT_MS)" --cmd "let g:vantage_debug_log_path='$(VANTAGE_DEBUG_LOG)'"
# This paid command-coverage tour intentionally has one fixed model target.
# Keep PI_DEV configurable for interactive development; never reuse it here.
override E2E_PI_DEV := --cmd "let g:vantage_dev_agent='pi' | let g:vantage_pi_provider='openai-codex' | let g:vantage_pi_model='gpt-5.6-luna' | let g:vantage_pi_reasoning='low' | let g:vantage_pi_timeout_ms=$(PI_TIMEOUT_MS) | let g:vantage_pi_annotation_timeout_ms=$(PI_ANNOTATION_TIMEOUT_MS) | let g:vantage_debug_log_path='$(E2E_DIR)/vantage.log'"

.PHONY: test run run-pi compile lint tail-debug test-dev-init test-dev-init-pi e2e-annotations e2e-model e2e-dirs stage-e2e-workspace trace-dirs dev-dirs

dev-dirs:
	mkdir -p "$(DEV_HOME)/config" "$(DEV_HOME)/data" "$(DEV_HOME)/state" "$(DEV_HOME)/cache"

e2e-dirs: dev-dirs
	mkdir -p "$(E2E_DIR)"

stage-e2e-workspace: e2e-dirs
	rm -rf "$(E2E_WORKSPACE)"
	mkdir -p "$(E2E_WORKSPACE)"
	cp -R "$(E2E_TEMPLATE)/." "$(E2E_WORKSPACE)"
	git -C "$(E2E_WORKSPACE)" init -q
	git -C "$(E2E_WORKSPACE)" add .
	git -C "$(E2E_WORKSPACE)" -c user.name='Vantage E2E' -c user.email='vantage-e2e@example.invalid' commit -qm fixture

trace-dirs: dev-dirs
	mkdir -p "$(TRACE_DIR)"

compile:
	$(NPM) run compile

lint:
	$(NPM) run lint

test: dev-dirs test-dev-init e2e-annotations
	$(DEV_ENV) $(NPM) run test:mvp

run: dev-dirs compile
	$(DEV_ENV) $(NVIM) $(DEV_ROOT) --noplugin -u "$(ROOT)/nvim/dev/init.lua" "$(FILE)"

run-pi: trace-dirs compile
	$(DEV_ENV) $(NVIM) $(DEV_ROOT) $(PI_DEV) --cmd "let g:vantage_pi_trace_prompt_path='$(TRACE_DIR)/pi-prompt.txt'" --cmd "let g:vantage_pi_trace_response_path='$(TRACE_DIR)/pi-response.txt'" --noplugin -u "$(ROOT)/nvim/dev/init.lua" "$(FILE)"

tail-debug:
	@tail -f '$(VANTAGE_DEBUG_LOG)'

e2e-annotations: e2e-dirs compile
	$(DEV_ENV) $(NVIM) $(DEV_ROOT) --cmd "let g:vantage_e2e_wait_ms=$(E2E_WAIT_MS)" --cmd "let g:vantage_e2e_artifact_path='$(E2E_DIR)/annotations.json'" --headless --noplugin -u "$(ROOT)/nvim/dev/init.lua" "$(ROOT)/README.md" -c "lua dofile('$(ROOT)/nvim/tests/e2e_annotations_spec.lua').run()" -c "qa!"
	@cat "$(E2E_DIR)/annotations.json"

e2e-model: stage-e2e-workspace compile
	cd "$(E2E_WORKSPACE)" && $(DEV_ENV) $(NVIM) $(DEV_ROOT) $(E2E_PI_DEV) --cmd "let g:vantage_e2e_wait_ms=$(E2E_WAIT_MS) | let g:vantage_e2e_codebase_path='$(E2E_WORKSPACE)' | let g:vantage_e2e_artifact_path='$(E2E_DIR)/model-all-commands.json'" --headless --noplugin -u "$(ROOT)/nvim/dev/init.lua" "$(E2E_WORKSPACE)/lua/calculator.lua" -c "lua dofile('$(ROOT)/nvim/tests/e2e_all_commands_spec.lua').run()" -c "qa!"
	@cat "$(E2E_DIR)/model-all-commands.json"

test-dev-init: dev-dirs compile
	$(DEV_ENV) $(NVIM) $(DEV_ROOT) --headless --noplugin -u "$(ROOT)/nvim/dev/init.lua" "$(ROOT)/README.md" -c "lua dofile('$(ROOT)/nvim/tests/dev_init_spec.lua').run()" -c qa

test-dev-init-pi: dev-dirs compile
	$(DEV_ENV) $(NVIM) $(DEV_ROOT) --cmd "let g:vantage_dev_agent='pi'" --headless --noplugin -u "$(ROOT)/nvim/dev/init.lua" "$(ROOT)/README.md" -c "lua dofile('$(ROOT)/nvim/tests/dev_init_spec.lua').run()" -c qa
