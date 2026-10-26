import Foundation

/// 类似 Java 的配置枚举：只控制展示区域，不修改图标顺序或布局 JSON。
enum GridDisplayMode: String, CaseIterable, Identifiable {
    case fullScreen
    case macBook14
    case macBook16
    case display24
    case display27

    var id: String { rawValue }

    func title(using localizer: Localizer) -> String {
        switch self {
        case .fullScreen: return localizer.text(.gridAreaFullScreen)
        case .macBook14: return localizer.text(.gridArea14)
        case .macBook16: return localizer.text(.gridArea16)
        case .display24: return localizer.text(.gridArea24)
        case .display27: return localizer.text(.gridArea27)
        }
    }

    var maximumSize: CGSize? {
        // 单位为 macOS 逻辑点，表示不同屏幕体验的居中区域，不按物理英寸测量屏幕。
        switch self {
        case .fullScreen: return nil
        case .macBook14: return CGSize(width: 1120, height: 790)
        case .macBook16: return CGSize(width: 1280, height: 900)
        case .display24: return CGSize(width: 1920, height: 1080)
        case .display27: return CGSize(width: 2160, height: 1215)
        }
    }

    var maximumIconSize: CGFloat {
        switch self {
        case .macBook14, .macBook16: return 78
        case .display24: return 112
        case .display27: return 128
        case .fullScreen: return 160
        }
    }
}

struct GridMetrics: Equatable {
    static let horizontalGridPadding: CGFloat = 14
    static let cellSpacing: CGFloat = 14
    let width: CGFloat
    let height: CGFloat
    let columns: Int
    let rows: Int
    let iconSize: CGFloat
    let pageViewportWidth: CGFloat

    static func captionFontSize(for iconSize: CGFloat) -> CGFloat { min(18, max(13, 13 * iconSize / 78)) }
    static func captionSpacing(for iconSize: CGFloat) -> CGFloat { min(16, max(9, 9 * iconSize / 78)) }

    init(screenSize: CGSize, displayMode: GridDisplayMode) {
        let isFullScreen = displayMode == .fullScreen
        // 全屏左右各留 10%、上下各留 5%；单位为逻辑点，最少保留原来的 44/36 点边距。
        let horizontalInset = isFullScreen ? max(44, screenSize.width * 0.10) : 44
        let verticalInset = isFullScreen ? max(36, screenSize.height * 0.05) : 36
        let availableWidth = max(1, screenSize.width - horizontalInset * 2)
        let availableHeight = max(1, screenSize.height - verticalInset * 2)
        // 超宽屏按可用高度限制网格比例，避免七列图标横向散开，额外空间留在两侧。
        let maximumWidth = displayMode.maximumSize?.width ?? availableHeight * 1.9
        width = min(maximumWidth, availableWidth)
        height = min(displayMode.maximumSize?.height ?? availableHeight, availableHeight)
        // 高竖屏改为 5 列 7 行，仍保留 35 个槽位，避免七列把图标挤小。
        let isTallGrid = isFullScreen && height > width && height >= 900
        columns = width < 760 || isTallGrid ? 5 : 7
        rows = height < 560 ? 4 : (isTallGrid ? 7 : 5)
        if displayMode.maximumIconSize > 78 {
            let cellWidth = max(1, (width - Self.horizontalGridPadding * 2 - CGFloat(columns - 1) * Self.cellSpacing) / CGFloat(columns))
            // 搜索栏和分页共占 142 点；按放大后的名称行高、图文间距及按钮内边距预留空间，避免裁切。
            let cellHeight = max(1, (height - 142 - CGFloat(rows - 1) * Self.cellSpacing) / CGFloat(rows))
            // 桌面预设和全屏随单元格放大，分别限制到 112/128/160 逻辑点。
            let proposedSize = min(displayMode.maximumIconSize, max(42, min(cellWidth * 0.68, cellHeight * 0.72)))
            let captionHeight = Self.captionFontSize(for: proposedSize) * 1.3 + Self.captionSpacing(for: proposedSize) + 14
            iconSize = max(42, min(proposedSize, cellHeight - captionHeight))
        } else {
            iconSize = min(78, max(42, min(width / CGFloat(columns) * 0.52, (height - 150) / CGFloat(rows) * 0.64)))
        }
        let contentWidth = max(1, width - Self.horizontalGridPadding * 2)
        let columnPitch = (contentWidth + Self.cellSpacing) / CGFloat(columns)
        // 静止网格尺寸不变，仅扩大翻页的绘制区域；空间不足时以真实屏幕为界。
        let requestedWidth = isFullScreen ? screenSize.width : contentWidth + columnPitch * 2
        pageViewportWidth = max(contentWidth, min(max(1, screenSize.width), requestedWidth))
    }
}

/// 类似 Java 的布局计算对象：页面步长取动画视口宽度，网格仍在每页中央。
/// 不能只放宽 clip，否则静止时就会露出相邻页面的图标。
struct PageViewportMetrics: Equatable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    var pageStride: CGFloat { viewportWidth }
    var contentInset: CGFloat { (viewportWidth - contentWidth) / 2 }

    init(contentWidth: CGFloat, viewportWidth: CGFloat? = nil) {
        self.contentWidth = max(1, contentWidth)
        self.viewportWidth = max(self.contentWidth, viewportWidth ?? self.contentWidth)
    }
}
