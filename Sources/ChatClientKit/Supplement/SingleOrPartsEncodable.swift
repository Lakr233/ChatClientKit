//
//  Created by ktiays on 2025/2/12.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

protocol SingleOrPartsEncodable {
    var encodableItem: any Encodable { get }
}

extension SingleOrPartsEncodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodableItem)
    }
}
