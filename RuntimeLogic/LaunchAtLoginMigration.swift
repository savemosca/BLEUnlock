enum LoginServiceStatus { case notRegistered, enabled, requiresApproval, unavailable }
enum LoginMigrationResult { case complete, requiresApproval, unavailable }

func migrateLoginService(status: () -> LoginServiceStatus,
                         register: () throws -> Void,
                         disableLegacy: () throws -> Void) throws -> LoginMigrationResult {
    if status() == .notRegistered { try register() }
    switch status() {
    case .enabled:
        try disableLegacy()
        return .complete
    case .requiresApproval:
        return .requiresApproval
    default:
        return .unavailable
    }
}
