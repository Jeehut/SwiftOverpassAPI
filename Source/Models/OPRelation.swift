//
//  OPRelation.swift
//  SwiftOverpassAPI
//
//  Created by Edward Samson on 10/2/19.
//  Copyright © 2019 Edward Samson. All rights reserved.
//

import MapKit

// A collection of related overpass members. Members can be nodes, ways (paths made up of nodes), and other relations.
public struct OPRelation: OPElement {

	public struct Member {
		
		public let type: OPElementType // The member's type
		public let id: Int // The member's unique identifier
		public let role: String // The role a member playes in the relation
		public let coordinates: [CLLocationCoordinate2D] // The coordinates of the member
		
		// Used to decode the member from an Overpass API JSON response.
		enum CodingKeys: String, CodingKey {
			case type, role, geometry, nodes
			case id = "ref"
		}
	}
	
	public let id: Int
	public let tags: [String: String]
	public let isInteresting: Bool // Relatin contains an interesting descriptive tag
	public var isSkippable: Bool // Relation is already rendered by a parent element
	public let members: [Int] // Members that form the relation
	public let geometry: OPGeometry // The relation's geometry type
    public let meta: OPMeta?
}

extension OPRelation {
	// Many relations are just collections of related objects, but these relation types require specific renderings
	static let displayableTypes: Set<String> = [
		Overpass.Values.multipolygon,
		Overpass.Values.barrier,
		Overpass.Values.route,
		Overpass.Values.waterway
	]
}
