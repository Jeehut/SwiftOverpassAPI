//
//  ElementCenter.swift
//  OverpassApiVisualizer
//
//  Created by Edward Samson on 10/7/19.
//  Copyright © 2019 Edward Samson. All rights reserved.
//

import CoreLocation

// Used to decode an element's center coordinate from an element's JSON dicitonary
struct ElementCenter {
	
	let latitude: Double
	let longitude: Double
}

extension ElementCenter: Decodable {
	enum CodingKeys: String, CodingKey {
		case laitude = "lat"
		case longitude = "lon"
	}
	
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		latitude = try container.decode(Double.self, forKey: .laitude)
		longitude = try container.decode(Double.self, forKey: .longitude)
	}
}

extension ElementCenter {
	func toCoordinate() -> CLLocationCoordinate2D {
		return CLLocationCoordinate2D(
			latitude: latitude,
			longitude: longitude)
	}
}
