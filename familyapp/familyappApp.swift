//
//  familyappApp.swift
//  familyapp
//
//  Created by wyc on 2026/9/18.
//

import SwiftUI
import SwiftData

/// Small, persisted appearance preferences shared by the app root and the
/// Settings form. This is intentionally not a theme system: system semantic
/// colors continue to supply all ordinary interface colors.
enum AppearancePreference {
    static let followSystemKey = "appearance.follow-system"
    static let darkModeKey = "appearance.dark-mode"
}

@main
struct familyappApp: App {
    private let container: ModelContainer
    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearancePreference.followSystemKey) private var followSystem = true
    @AppStorage(AppearancePreference.darkModeKey) private var darkMode = false

    init() {
        do {
            container = try ModelContainer(for: MemberProfile.self, SemesterModel.self,
                                           ScheduleEntryModel.self, ScheduleExceptionModel.self,
                                           ScheduleImportBatchModel.self,
                                           CalendarOverrideModel.self,
                                           AgendaItemModel.self, AgendaExceptionModel.self, MemoModel.self, NoticeModel.self,
                                           NoticeReadModel.self, ChatMessageModel.self,
                                           LocationSnapshotModel.self, MemberStatusModel.self, FamilyPlaceModel.self,
                                           PendingMutationModel.self, SyncStateModel.self,
                                           RemoteEntityRecordModel.self, SyncConflictModel.self,
                                           PendingImportBatchRollbackModel.self,
                                           MessageReceiptModel.self)
        } catch {
            fatalError("Unable to create the local data store: \(error.localizedDescription)")
        }
        _environment = State(initialValue: AppEnvironment(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .modelContainer(container)
                .tint(Color("AccentColor"))
                .preferredColorScheme(preferredColorScheme)
                .onChange(of: scenePhase) { _, phase in environment.locationScenePhaseChanged(phase) }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        guard !followSystem else { return nil }
        return darkMode ? .dark : .light
    }
}
