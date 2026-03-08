# AI Assistant Instructions

These instructions are to be followed by the AI programming assistant when working in this repository.

## 1. Adding New Applications
When requested to add a new application to the VPS Orchestrator, always perform the following steps:
- **Create Installer**: Write the installation script (`apps/<category>/<app_name>/install.sh`) following the existing codebase patterns (using `lib/utils.sh` functions).
- **Register App**: Add the application configuration block to `config/apps.conf`.
- **Update Orchestrator Detection**: You **MUST** update the `is_app_installed` function in `orchestrator.sh` so the application's installation status is correctly detected by the interactive menu.
- **Update Documentation**: Update `README.md` to list the new application in the relevant section under the "Applications Catalog".
- **Update Changelog**: Update `CHANGELOG.md` with a new version entry detailing the addition.

## 2. Language & Documentation Constraints
- All code comments, commit messages, and repository documentation (README, script outputs, changelogs, this file) **MUST be written in English**.
- User communication (in chat or notifications) should adapt to the language the user speaks.

## 3. General Best Practices
- Follow existing patterns for logging (`log_info`, `log_success`, `log_step`, `log_error`), OS detection (`detect_os`, `require_debian`), and error handling (`cleanup_on_error`).
- Default to using native package managers (e.g., APT repository for Debian/Ubuntu environments) over third-party alternatives like Linuxbrew unless strictly necessary or verified.
- Ensure scripts handle permissions carefully (e.g., using `run_sudo` appropriately and ensuring configurations are readable to intended users).

## 4. Research and Planning
- **MCP Tools Utilization**: Before creating any implementation plan, you **MUST** leverage all available MCP (Model Context Protocol) tools (such as web search, documentation retrieval, or codebase context tools) to find the latest available information. This ensures that the solutions are aligned with the most current technology trends, software versions, and best practices.
