import SwiftUI
import PKDKit

struct EntryListView: View {
    let info: PkgInfo

    private var groups: [(name: String, entries: [PkgEntryInfo])] {
        let grouped = Dictionary(grouping: info.entries) { $0.group }
        return grouped
            .map { (name: $0.key, entries: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.name) { group in
                DisclosureGroup {
                    ForEach(group.entries, id: \.path) { entry in
                        row(entry)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(group.name)
                            .font(.callout.weight(.medium))
                        Text("\(group.entries.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func row(_ entry: PkgEntryInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: entry.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(shortName(entry.path))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 18)
        .padding(.vertical, 1)
        .help(entry.path)
    }

    private func shortName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func icon(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "tex": return "photo"
        case "json": return "curlybraces"
        case "frag", "vert": return "square.stack.3d.up"
        default: return "doc"
        }
    }
}
