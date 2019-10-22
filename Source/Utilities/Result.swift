//
//  Result.swift
//  OverpassApiVisualizer
//
//  Created by Edward Samson on 10/5/19.
//  Copyright © 2019 Edward Samson. All rights reserved.
//

import Foundation

// A generic class that either returns a successful result of the specified type or an error
enum Result<T> {
	case success(T)
	case failure(Error)
}
