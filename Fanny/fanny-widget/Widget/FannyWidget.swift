//
//  FannyWidget.swift
//  FannyWidget
//
//  WidgetKit replacement for the legacy Notification Center widget.
//

import SwiftUI
import WidgetKit

struct FannyWidgetEntry: TimelineEntry {
    let date: Date
    let fans: [Fan]
    let cpuTemperature: Temperature?
    let gpuTemperature: Temperature?
}

struct FannyWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> FannyWidgetEntry {
        return FannyWidgetEntry(date: Date(),
                                fans: [],
                                cpuTemperature: nil,
                                gpuTemperature: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FannyWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FannyWidgetEntry>) -> Void) {
        // WidgetKit budgets reloads, so very short app refresh intervals are
        // clamped here. The menu bar app still refreshes at the chosen rate.
        let interval: TimeInterval = max(FNYUserPreferences.monitorRefreshTimeIntervalOption().timeInterval, 15.0)
        let timeline: Timeline<FannyWidgetEntry> = Timeline(entries: [currentEntry()],
                                                            policy: .after(Date().addingTimeInterval(interval)))
        completion(timeline)
    }

    private func currentEntry() -> FannyWidgetEntry {
        return FannyWidgetEntry(date: Date(),
                                fans: FNYLocalStorage.fans(),
                                cpuTemperature: FNYLocalStorage.cpuTemperature(),
                                gpuTemperature: FNYLocalStorage.gpuTemperature())
    }

}

struct FannyWidgetEntryView: View {

    var entry: FannyWidgetProvider.Entry

    @Environment(\.widgetFamily) private var widgetFamily

    private let unavailableValue: String = "--"

    var body: some View {
        VStack(alignment: .leading, spacing: 8.0) {
            HStack {
                Text("Fanny")
                    .font(.headline)
                Spacer()
            }

            temperatureRow(title: "CPU", temperature: entry.cpuTemperature)
            temperatureRow(title: "GPU", temperature: entry.gpuTemperature)

            if !entry.fans.isEmpty {
                Divider()
                ForEach(Array(entry.fans.prefix(maxFanCount)), id: \.identifier) { fan in
                    HStack {
                        Text("Fan #\(fan.identifier + 1)")
                        Spacer()
                        Text(fan.currentRPM.map({ "\($0) RPM" }) ?? unavailableValue)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
    }

    private var maxFanCount: Int {
        switch widgetFamily {
        case .systemSmall: return 2
        default: return 4
        }
    }

    private func temperatureRow(title: String, temperature: Temperature?) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(temperature?.formattedTemperature() ?? unavailableValue)
                .fontWeight(.semibold)
        }
    }

}

@main
struct FannyWidget: Widget {
    private let kind: String = "FannyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FannyWidgetProvider()) { entry in
            FannyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Fanny")
        .description("Shows fan speed and CPU/GPU temperature from the Fanny menu bar app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FannyWidget_Previews: PreviewProvider {
    static var previews: some View {
        FannyWidgetEntryView(entry: FannyWidgetEntry(date: Date(),
                                                    fans: [],
                                                    cpuTemperature: nil,
                                                    gpuTemperature: nil))
            .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}
