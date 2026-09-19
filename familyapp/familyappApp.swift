//
//  familyappApp.swift
//  familyapp
//
//  Created by wyc on 2026/9/18.
//

import SwiftUI
import SwiftData

@main
struct familyappApp: App {
    private let container: ModelContainer
    @State private var environment: AppEnvironment

    init() {
        do {
            container = try ModelContainer(for: MemberProfile.self, SemesterModel.self,
                                           ScheduleEntryModel.self, ScheduleExceptionModel.self,
                                           CalendarOverrideModel.self,
                                           AgendaItemModel.self, AgendaExceptionModel.self, MemoModel.self, NoticeModel.self,
                                           NoticeReadModel.self, ChatMessageModel.self,
                                           LocationSnapshotModel.self, FamilyPlaceModel.self)
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
        }
    }
}
