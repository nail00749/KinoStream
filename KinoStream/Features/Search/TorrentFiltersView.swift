import SwiftUI

struct TorrentFiltersView: View {
    @Binding var filters: TorrentSearchFilters
    let shown: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Качество", selection: $filters.quality) {
                    ForEach(TorrentSearchFilters.qualities, id: \.self) { Text($0).tag($0) }
                }
                Picker("Размер", selection: $filters.maximumSizeGB) {
                    Text("Любой").tag(0)
                    ForEach([5, 10, 20, 50, 100], id: \.self) { Text("До \($0) ГБ").tag($0) }
                }
                Picker("Сиды", selection: $filters.minimumSeeders) {
                    Text("Любые").tag(0)
                    ForEach([1, 5, 10, 50], id: \.self) { Text("От \($0)").tag($0) }
                }
            }
            HStack {
                Picker("Язык", selection: $filters.language) {
                    ForEach(TorrentSearchFilters.languages, id: \.self) { Text($0).tag($0) }
                }
                Picker("Озвучка", selection: $filters.dubbing) {
                    ForEach(TorrentSearchFilters.dubbings, id: \.self) { Text($0).tag($0) }
                }
                Picker("Порядок", selection: $filters.sort) {
                    ForEach(TorrentSearchFilters.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Text("\(shown) из \(total) · Язык и озвучка — по названию раздачи")
                    .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                Spacer()
                Button("Сбросить") { filters = TorrentSearchFilters() }
                    .buttonStyle(.plain).foregroundStyle(KinoPalette.accent)
                    .disabled(filters == TorrentSearchFilters())
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 10))
    }
}
