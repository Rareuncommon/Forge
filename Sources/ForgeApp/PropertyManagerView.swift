import ForgeCommands
import ForgeCore
import ForgeUI
import SwiftUI


struct PropertyManagerView: View {
    @Environment(AppModel.self) private var model
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let op = model.operation {
                        OperationPage(op: op)
                    } else if let tool = model.sketchState.tool {
                        SketchToolPage(tool: tool)
                    } else if model.activeSketch != nil {
                        SketchPage()
                    } else {
                        SelectionPage()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.line2).frame(height: 1)
            PMGroup("History", isOpen: $showHistory) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.log.suffix(60).enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .background(Theme.panel)
    }
}
