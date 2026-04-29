import Metal

enum Q3GLBlendFactor: UInt32 {
    case zero = 0x0000
    case one = 0x0001
    case srcColor = 0x0300
    case oneMinusSrcColor = 0x0301
    case srcAlpha = 0x0302
    case oneMinusSrcAlpha = 0x0303
    case dstAlpha = 0x0304
    case oneMinusDstAlpha = 0x0305
    case dstColor = 0x0306
    case oneMinusDstColor = 0x0307
}

enum Q3MetalStateMap {
    static func blendFactor(_ raw: UInt32) -> MTLBlendFactor {
        switch Q3GLBlendFactor(rawValue: raw) {
        case .zero: return .zero
        case .one: return .one
        case .srcColor: return .sourceColor
        case .oneMinusSrcColor: return .oneMinusSourceColor
        case .srcAlpha: return .sourceAlpha
        case .oneMinusSrcAlpha: return .oneMinusSourceAlpha
        case .dstAlpha: return .destinationAlpha
        case .oneMinusDstAlpha: return .oneMinusDestinationAlpha
        case .dstColor: return .destinationColor
        case .oneMinusDstColor: return .oneMinusDestinationColor
        case .none: return .one
        }
    }

    static func cullMode(_ q3CullType: UInt32) -> MTLCullMode {
        switch q3CullType {
        case 0: return .none
        case 1: return .back
        case 2: return .front
        default: return .back
        }
    }

    static func depthCompare(_ q3DepthFunc: UInt32) -> MTLCompareFunction {
        switch q3DepthFunc {
        case 0: return .lessEqual
        case 1: return .equal
        default: return .lessEqual
        }
    }
}

