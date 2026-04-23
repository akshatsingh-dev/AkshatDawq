import SwiftUI

/// User health profile — drift prevention UI.
/// User confirms or corrects DAWQ's understanding of their health.
/// Non-negotiable architectural safeguard.
struct ProfileView: View {
    @State private var profile = UserHealthProfile.empty()
    @State private var isEditing = false
    @StateObject private var cactus = CactusManager.shared

    var body: some View {
        NavigationStack {
            List {
                // On-device AI
                Section("On-Device AI") {
                    HStack {
                        if let model = cactus.activeModel {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.displayName).foregroundStyle(.primary)
                                    Text("\(model.paramCount) · \(model.sizeGB) GB · on-device")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: model.icon).foregroundStyle(model.accentColor)
                            }
                        } else {
                            Label("Preparing default model", systemImage: "cpu")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                // Drift confirmation status
                Section {
                    if let confirmed = profile.lastConfirmedAt {
                        Label(
                            "Confirmed \(confirmed, style: .relative) ago",
                            systemImage: "checkmark.seal.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        Label("Profile not yet confirmed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    ForEach(profile.conditionsList, id: \.self) { condition in
                        Text(condition)
                    }
                    if profile.conditionsList.isEmpty {
                        Text("None logged").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Conditions")
                }

                Section {
                    ForEach(profile.medicationsList, id: \.self) { med in
                        Text(med)
                    }
                    if profile.medicationsList.isEmpty {
                        Text("None logged").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Medications")
                }

                Section {
                    ForEach(profile.allergiesList, id: \.self) { allergy in
                        Text(allergy)
                    }
                    if profile.allergiesList.isEmpty {
                        Text("None logged").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Allergies")
                }

                // Confirm button
                Section {
                    Button {
                        Task { await confirmProfile() }
                    } label: {
                        Label("This is accurate", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                // Privacy note
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Stays on your device", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("This data never leaves your phone. Cloud queries use an anonymized abstract only.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Health Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { isEditing = true }
                }
            }
            .task { profile = (try? DatabaseManager.shared.userProfile()) ?? .empty() }
            .sheet(isPresented: $isEditing) {
                ProfileEditSheet(profile: $profile, isPresented: $isEditing)
            }
        }
    }

    private func confirmProfile() async {
        var updated = profile
        updated.lastConfirmedAt = Date()
        updated.lastUpdatedAt = Date()
        _ = try? DatabaseManager.shared.write { try updated.save($0) }
        profile = updated
    }
}

struct ProfileEditSheet: View {
    @Binding var profile: UserHealthProfile
    @Binding var isPresented: Bool

    @State private var conditions = ""
    @State private var medications = ""
    @State private var allergies = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Conditions (comma-separated)") {
                    TextField("e.g. migraines, IBS, Hashimoto's", text: $conditions, axis: .vertical)
                        .lineLimit(3)
                }
                Section("Medications (comma-separated)") {
                    TextField("e.g. levothyroxine 50mcg, ibuprofen as needed", text: $medications, axis: .vertical)
                        .lineLimit(3)
                }
                Section("Allergies (comma-separated)") {
                    TextField("e.g. penicillin, latex", text: $allergies, axis: .vertical)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                }
            }
            .onAppear {
                conditions = profile.conditionsList.joined(separator: ", ")
                medications = profile.medicationsList.joined(separator: ", ")
                allergies = profile.allergiesList.joined(separator: ", ")
            }
        }
    }

    private func save() async {
        let parseList: (String) -> [String] = { str in
            str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var updated = profile
        updated.confirmedConditions = UserHealthProfile.encode(parseList(conditions))
        updated.confirmedMedications = UserHealthProfile.encode(parseList(medications))
        updated.confirmedAllergies = UserHealthProfile.encode(parseList(allergies))
        updated.lastUpdatedAt = Date()

        _ = try? DatabaseManager.shared.write { try updated.save($0) }
        profile = updated
        isPresented = false
    }
}
