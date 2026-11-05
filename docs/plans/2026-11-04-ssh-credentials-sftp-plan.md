# SSH Credentials, Connection & SFTP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Follow TDD (RED-GREEN-REFACTOR) and Verification-Before-Completion. Every task ends with an independently testable deliverable and verified test suite execution.

**Goal:** Implement Phase 1 of Herb's Terminal: encrypted SQLite/Keychain credential store, CSV import/export with duplicate conflict resolution, "Connect via SSH" UI sheet with saved account picker, host-following remote explorer, and SFTP file operations.

**Architecture:** 
1. `CredentialVault`: SQLite3 store (`herbsterminal_logins.db`) with AES-GCM encrypted passwords using a 256-bit symmetric key stored in macOS Keychain.
2. `LoginCSV`: Validated transactional CSV import with duplicate conflict policies (overwrite, skip, keep both) and encrypted store sync.
3. `SSHConnectSheet`: SwiftUI modal sheet for manual or saved SSH connection, supporting one-time use or saving credentials.
4. `RemoteSessionManager` & `RemoteExplorer`: Tab-bound remote session that follows the verified remote host, attaches `SFTPClient` to the explorer pane, and restores local explorer on disconnect.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, SwiftTerm, libsqlite3 (`import SQLite3`), Apple CryptoKit (`AES.GCM`), macOS Security framework (`Keychain`).

**Spec:** [`SPECIFICATION.md`](file:///Users/me/Projects/HerbsTerminal/SPECIFICATION.md) Sections 1, 3, 4, 5, 9, 10.

## Global Constraints
- Target platform: macOS 15.0+ on Apple Silicon (arm64).
- Terminal Basic profile (SF Mono 11pt) and theme must be preserved across sessions.
- Passwords must NEVER appear in process arguments, terminal history, or logs.
- SQLite database transactions must roll back on failure or rejected CSV imports.
- Passwords containing quotes, commas, and unicode linebreaks must round-trip exactly.
- Build system: SwiftPM with `--build-system native` to maintain SwiftTerm compilation without requiring the external metal tool.

---

### Task 1: Keychain & AES-GCM Encryption Key Provider
**Files:**
- Create: `Sources/HerbsTerminal/KeychainVault.swift`
- Test: `Tests/HerbsTerminalTests/KeychainVaultTests.swift`

**Interfaces:**
- Produces: `protocol KeyProvider { func encryptionKey() throws -> SymmetricKey }`, `KeychainKeyProvider: KeyProvider`, `MockKeyProvider: KeyProvider`
- Throws typed `VaultError` if Keychain item is inaccessible.

- [ ] **Step 1: Write the failing unit test**
  - Test generating or retrieving a persistent 256-bit AES symmetric key in test/mock mode.
  - Test encryption and decryption of secret text (including unicode, quotes, commas).
- [ ] **Step 2: Verify RED**
  - Run `bash script/test.sh` and verify compilation failure / missing type.
- [ ] **Step 3: Implement minimal KeychainKeyProvider and AES-GCM helper**
  - Use `CryptoKit.AES.GCM` for authenticated encryption (`AES.GCM.seal` / `AES.GCM.open`).
  - Use `Security` framework for macOS Keychain operations (`kSecClassGenericPassword`).
- [ ] **Step 4: Verify GREEN**
  - Run `bash script/test.sh` and verify all tests pass.
- [ ] **Step 5: Commit**
  - `git commit -m "feat(vault): add Keychain key provider and AES-GCM encryption helpers"`

---

### Task 2: SQLite Credential Store (CRUD & Transactional Import)
**Files:**
- Create: `Sources/HerbsTerminal/CredentialStore.swift`
- Test: `Tests/HerbsTerminalTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces: `class CredentialStore: ObservableObject`
  - `init(databaseURL: URL?, keyProvider: KeyProvider)`
  - `func save(_ login: SSHLogin) throws`
  - `func list() throws -> [SSHLogin]`
  - `func delete(id: SSHLogin.ID) throws`
  - `func importCSV(_ data: Data, conflictPolicy: ConflictPolicy) throws -> ImportSummary`
  - `func exportCSV() throws -> Data`

- [ ] **Step 1: Write failing unit test**
  - Test CRUD operations on a SQLite database in a temporary directory.
  - Test multiple usernames for the same host.
  - Test transaction rollback when a record in a multi-record CSV is malformed.
  - Test round-trip of password with commas, quotes, and UTF-8 characters.
- [ ] **Step 2: Verify RED**
  - Run `bash script/test.sh` and observe failure.
- [ ] **Step 3: Implement CredentialStore**
  - Schema: `CREATE TABLE IF NOT EXISTS logins (host TEXT, port INTEGER, username TEXT, ciphertext BLOB, nonce BLOB, tag BLOB, PRIMARY KEY (host, port, username))`
  - SQLite prepared statements with parameter binding (safe from SQL injection).
  - Transactional CSV import wrapping `LoginCSV.decode`.
- [ ] **Step 4: Verify GREEN**
  - Run `bash script/test.sh` and confirm all tests pass.
- [ ] **Step 5: Commit**
  - `git commit -m "feat(credentials): implement SQLite credential store with AES-GCM encryption"`

---

### Task 3: "Connect via SSH" UI & Account Picker
**Files:**
- Create: `Sources/HerbsTerminal/SSHConnectView.swift`
- Modify: `Sources/HerbsTerminalUI/SessionToolbar.swift` (add or expose SSH connect action in menu/toolbar)
- Modify: `Sources/HerbsTerminal/WorkspaceView.swift` (wire sheet presentation)
- Test: `Tests/HerbsTerminalTests/SSHConnectViewTests.swift`

**Interfaces:**
- Produces: `SSHConnectView` sheet with:
  - Host, Port (default 22), Username, Password fields.
  - Saved accounts dropdown / picker from `CredentialStore`.
  - "Save to Logins" checkbox.
  - CSV Import & Export buttons with file picker and conflict resolution confirmation.
  - "Connect" and "Cancel" buttons.

- [ ] **Step 1: Write failing test / view verification**
  - Test account picker filtering and selection binding.
  - Test credential validation before triggering connection.
- [ ] **Step 2: Verify RED**
- [ ] **Step 3: Implement SSHConnectView and menu integration**
  - Wire into Main Menu ("Connect via SSH…") with shortcut `Cmd+K` or menu item.
- [ ] **Step 4: Verify GREEN**
  - Run `bash script/test.sh` and `bash script/build_and_run.sh --verify`.
- [ ] **Step 5: Commit**
  - `git commit -m "feat(ui): add SSH connection modal and saved account picker"`

---

### Task 4: Host-Following Remote Session & SFTP Explorer
**Files:**
- Create: `Sources/HerbsTerminal/RemoteSession.swift`
- Create: `Sources/HerbsTerminal/RemoteExplorer.swift`
- Modify: `Sources/HerbsTerminal/WorkspaceView.swift` (manage tab connection state)
- Modify: `Sources/HerbsTerminal/SessionView.swift` (switch explorer pane based on session type)
- Test: `Tests/HerbsTerminalTests/RemoteExplorerTests.swift`

**Interfaces:**
- Produces:
  - `enum SessionTarget: Equatable`: `.local` vs `.remote(RemoteEndpoint)`
  - `RemoteSession`: Holds SSH terminal process + SFTP channel.
  - `RemoteExplorer`: SwiftUI file explorer view consuming `SFTPClient` for remote navigation, mkdir, rename, delete, and hidden file visibility.

- [ ] **Step 1: Write failing test**
  - Test tab session target switching between `.local` and `.remote`.
  - Test remote directory path parsing, sorting, and hidden file filtering.
- [ ] **Step 2: Verify RED**
- [ ] **Step 3: Implement RemoteSession and RemoteExplorer**
  - Connect tab legend to show `username@remotehost remote_dir`.
  - Display remote files and allow directory traversal, parent folder, refresh.
- [ ] **Step 4: Verify GREEN**
  - Run `bash script/test.sh` and `bash script/build_and_run.sh --verify`.
- [ ] **Step 5: Commit**
  - `git commit -m "feat(sftp): implement host-following remote explorer pane"`

---

### Task 5: File Transfers & Remote Editing
**Files:**
- Create: `Sources/HerbsTerminal/TransferQueue.swift`
- Create: `Sources/HerbsTerminal/RemoteEditor.swift`
- Test: `Tests/HerbsTerminalTests/TransferQueueTests.swift`

**Interfaces:**
- Produces:
  - `TransferQueue`: Upload and download jobs, progress tracking, conflict resolution (replace using `posix-rename@openssh.com`).
  - `RemoteEditor`: Downloads remote file to temporary cache directory, opens with `NSWorkspace.open()`, observes file modifications, and uploads back to remote on save.

- [ ] **Step 1: Write failing test**
  - Test transfer queue enqueue, progress calculation, error reporting, retry.
  - Test safe overwrite via POSIX rename.
- [ ] **Step 2: Verify RED**
- [ ] **Step 3: Implement TransferQueue & RemoteEditor**
- [ ] **Step 4: Verify GREEN**
  - Run `bash script/test.sh` and `bash script/build_and_run.sh --verify`.
- [ ] **Step 5: Commit**
  - `git commit -m "feat(transfers): implement transfer queue and remote editor integration"`
