//
//  Extension+String.swift
//  ChatClientKit
//
//  Created by 秋星桥 on 2/26/25.
//

import Foundation

extension String {
    func trimmingCharactersFromStart(in set: CharacterSet) -> String {
        var duplicate = self
        while let firstCharacter: Character = duplicate.first,
              firstCharacter.unicodeScalars.count == 1, // TODO: Better Handling
              let firstScalar = firstCharacter.unicodeScalars.first,
              set.contains(firstScalar)
        {
            duplicate.removeFirst()
        }
        return duplicate
    }

    func trimmingCharactersFromEnd(in set: CharacterSet) -> String {
        var duplicate = self
        while let lastCharacter: Character = duplicate.last,
              lastCharacter.unicodeScalars.count == 1, // TODO: Better Handling
              let firstScalar = lastCharacter.unicodeScalars.first,
              set.contains(firstScalar)
        {
            duplicate.removeLast()
        }
        return duplicate
    }
}
