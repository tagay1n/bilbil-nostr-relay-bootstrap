SHELL := /bin/bash

.PHONY: help quality quality-deps hooks-install up down status restart logs

help:
	@echo "Available targets:"
	@echo "  make quality      - run repository quality gate"
	@echo "  make quality-deps - install jq/shellcheck/yamllint for hooks and local checks"
	@echo "  make hooks-install - install git hooks from .githooks"
	@echo "  make up           - run local dev stack in foreground (Ctrl+C stops all)"
	@echo "  make status       - show local dev stack status"
	@echo "  make down         - stop local dev stack"
	@echo "  make restart      - restart local dev stack"
	@echo "  make logs         - tail local dev logs"

quality:
	./scripts/stack.sh quality

quality-deps:
	./scripts/install_quality_deps.sh

hooks-install:
	./scripts/install_quality_deps.sh
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit
	@echo "Git hooks installed. pre-commit now runs ./scripts/quality_gate.sh"

up:
	./scripts/stack.sh up

down:
	./scripts/stack.sh down

status:
	./scripts/stack.sh status

restart: down up

logs:
	./scripts/stack.sh logs
