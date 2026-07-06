import SwiftUI

struct SettingsView: View {
    let auth: AuthService
    @Bindable var vm: MemoListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var deleting = false

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
    }
    private var providerLabel: String {
        switch auth.provider {
        case "google": "Google"
        case "apple": "Apple"
        case let p?: p.capitalized
        default: "—"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("계정") {
                    if let email = auth.email {
                        LabeledContent("이메일", value: email)
                    }
                    LabeledContent("로그인", value: providerLabel)
                }

                Section("정리") {
                    NavigationLink {
                        CategoryManageView(vm: vm)
                    } label: {
                        LabeledContent("카테고리 관리", value: "\(vm.allCategories.count)")
                    }
                }

                Section {
                    Button("로그아웃") {
                        Task { await auth.signOut(); dismiss() }
                    }
                    .foregroundStyle(AppColor.textPrimary)
                }

                Section("앱 정보") {
                    LabeledContent("버전", value: appVersion)
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if deleting { ProgressView() } else { Text("계정 삭제") }
                    }
                    .disabled(deleting)
                } footer: {
                    Text("계정과 모든 메모·카테고리가 영구 삭제됩니다.")
                }

                if let err = auth.lastError {
                    Text(err).font(.appCaption).foregroundStyle(AppColor.danger)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .confirmationDialog("계정을 삭제할까요? 되돌릴 수 없어요.",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("계정 삭제", role: .destructive) {
                    deleting = true
                    Task {
                        let ok = await auth.deleteAccount()
                        deleting = false
                        if ok { dismiss() }
                    }
                }
                Button("취소", role: .cancel) {}
            }
        }
    }
}
