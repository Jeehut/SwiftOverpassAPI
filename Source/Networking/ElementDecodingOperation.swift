//
//  ElementDecodingOperation.swift
//  OverpassApiVisualizer
//
//  Created by Edward Samson on 10/13/19.
//  Copyright © 2019 Edward Samson. All rights reserved.
//

import CoreLocation

/*
	An operation that decodes the JSON response from an Overpass API request in a dictionary of elements (nodes, ways, and relations). I chose to make decoding an operation so that if a client makes a newer query it can cancel decoding the old query and the new query's decoding process won't start until the cancelled decoding process has been removed.
*/

class ElementDecodingOperation: Operation {
	
	private var _elements = [Int: Element]() // Decoded Overpass elements from JSON data
	private var _error: Error?
	private let data: Data // Data to be decoded
	
	// Decoded elements can only be read after the operation is finished. Not sure if this is neccesary for safety, but it prevents the elements dictionary from being read from a different thread while writes are occuring on the operation's thread.
	var elements: [Int: Element] {
		guard isFinished else {
			return [:]
		}
		return _elements
	}
	
	var error: Error? {
		guard isFinished else {
			return nil
		}
		return _error
	}
	
	// Operation is initialized w/ data to be decoded
	init(data: Data) {
		self.data = data
	}
	
	// Main function of the operation
	override func main() {
		do {
			try decodeElements(from: data)
		} catch {
			self._error = error
		}
	}
	
	private func decodeElements(from data: Data) throws {
		
		// JSON decoder for decoding response
		let jsonDecoder = JSONDecoder()
		
		// In order to create containers for decoding our data outside of the init(from: Decoder) function, we have to do something a little hackey and create a struct with the sole purpose of initializing a decoder that holds our JSON data.
		let decoderExtractor = try jsonDecoder.decode(DecoderExtractor.self, from: data)
		let decoder = decoderExtractor.decoder
		
		// Container for the entire JSON response
		let container = try decoder.container(keyedBy: ElementsCodingKeys.self)
		
		// Nested container for the elements array in our JSON response, we will step through this container to decode each element in the array.
		let elementsContainer = try container.nestedUnkeyedContainer(
		forKey: .elements)
		
		let elementTypes: [ElementType] = [.node, .way, .relation]
		
		for elementType in elementTypes {
			
			// Because the decoding process requires us to decodes nodes first, arrays second, and relations last, we need to step through our elements container 3 times in total to decode everything in the correct order. In each decoding pass through the elements array, the unkeyed container decodes the element at the current index and then automatically steps through to the next index until it reaches the end. Since there is no way to reset a container's index to zero and make another pass through the array after the container reaches the end index, we have to create a copy of the elements container for each individual decoding pass we make. Maybe it would be better to switch to decoding JSON the without using unkeyed containers, since it feels like I'm using them in a way that was differs from what Apple intended.
			var elementsContainerCopy = elementsContainer
			
			while elementsContainerCopy.isAtEnd {
				
				if isCancelled {
					return
				}
				
				do {
					// Create a nested container for each individual element in the array, this automatically moves the current index of the parent container to the next index in the elements array.
					let elementContainer = try elementsContainerCopy.nestedContainer(
						keyedBy: ElementCodingKeys.self)
					
					// Find the element's type using the nested container. Skip the decoding process if the element's type should not be decoded for this step.
					let type = try elementContainer.decode(ElementType.self, forKey: .type)
					guard elementType == type else { continue }
					
					// Decode the element
					let element: Element
					
					switch elementType {
					case .node:
						element = try decodeNode(within: elementContainer)
					case .way:
						element = try decodeWay(within: elementContainer)
					case .relation:
						element = try decodeRelation(within: elementContainer)
					}
					
					// Add to elements dictionary if decoding was successful
					_elements.updateValue(element, forKey: element.id)
				} catch {
					// We want to catch any decoding errors for individual elements so a bad element does not stop the entire decoding process.
					print(error.localizedDescription)
				}
			}
		}
	}
	
	// A function for decoding a node inside of a keyed container. This could be done by adding an init(from: Decoder) to our nodes class, but since we can't do the same for Ways and Relations (they require information outside of the decoder to be constructed) I opted for to do it in a separate function to keep things consstent.
	private func decodeNode(within container: KeyedDecodingContainer<ElementCodingKeys>) throws -> Node {
		
		// Decode the node's id number
		let id = try container.decode(Int.self, forKey: .id)
		
		// If present, decode the tag dictionary that provides additional element details. Then check to see if any interesting tags are present. The isInteresting property is useful for determining whether or not to plot an element.
		let tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
		let isInteresting = TagChecker.checkForInterestingTags(amongstTags: tags)
		
		// Decode the coordinate of the node
		let latitude = try container.decode(Double.self, forKey: .latitude)
		let longitude = try container.decode(Double.self, forKey: .longitude)
		let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
		
		// Return the decoded node
		return Node(
			id: id,
			tags: tags,
			isInteresting: isInteresting,
			isSkippable: false,
			geometry: .center(coordinate))
	}
	
	// A function for decoding a way inside of a keyed container.
	private func decodeWay(within container: KeyedDecodingContainer<ElementCodingKeys>) throws -> Way {
		
		// Decode the way's id number
		let id = try container.decode(Int.self, forKey: .id)
		
		// If present, decode the tag dictionary that provides additional element details. Then check to see if any interesting tags are present. The isInteresting property is useful for determining whether or not to plot an element.
		let tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
		let isInteresting = TagChecker.checkForInterestingTags(amongstTags: tags)
		
		// Decode the ids of each child node make denotes a coorindate in the way's geometry
		let nodes = try container.decode([Int].self, forKey: .nodes)
		
		// A coordinate or collection of coordinates that describes the way's geometry. Varies depending on the output format of the query.
		let geometry: ElementGeometry
		
		// If center was specified as the output format, the center key will be present in the way's JSON dictionary. If present, decode the way's center and make the geometry a single coordinate.
		if let center = try container.decodeIfPresent(
			ElementCenter.self,
			forKey: .center)
		{
			let coordinate = CLLocationCoordinate2D(
				latitude: center.latitude,
				longitude: center.longitude)
			
			geometry = .center(coordinate)
			
			
		} else {
			// If center was not specified, we will attempt to create the way's full geometry.
			
			let coordinates: [CLLocationCoordinate2D]
	
			// If the output type geometry was specified, the full geometry will already be present in the geometry key of the way's dictionary.
			if let fullGeometry = try container.decodeIfPresent(
				[[String: Double]].self,
				forKey: .geometry)
			{
				// after decoding the geometry array, we convert it too an array of coordinates
				coordinates = fullGeometry.compactMap {
					guard
						let latitude = $0[Overpass.Keys.latitude],
						let longitude = $0[Overpass.Keys.longitude]
					else {
						return nil
					}
					return CLLocationCoordinate2D(
						latitude: latitude,
						longitude: longitude)
				}
				
			} else {
				
				// If full geometry was not specified, we will attempt to get the coordinates for each of the way's points from previously decoded nodes. This is why I've chosen to decode all of the nodes prior to decoding the ways. I've tried decoding all of the element types in one step and then constructing the geometries later, but this felt slightly cleaner to me.
				coordinates = nodes.compactMap {
					// If the element's geometry is a single coordinate, add it too the way's geometry array. Otherwise, return nil
					guard case .center(let coordinate) = elements[$0]?.geometry else {
						return nil
					}
					return coordinate
				}
			}
			
			// If there was an error generating any of the way's child coordinates, throw an error
			guard coordinates.count == nodes.count else {
				throw ElementDecodingError.invalidWayLength(wayId: id)
			}
			
			// Check whether or not the way is a polygon, set the geometry enum accordingly.
			let isPolygon = PolygonChecker.checkWay(
				withCoordinates: coordinates,
				andTags: tags)
			
			if isPolygon {
				geometry = .polygon(coordinates)
			} else {
				geometry = .polyline(coordinates)
			}
		}
		
		// Return the decoded way
		return Way(
			id: id,
			tags: tags,
			isInteresting: isInteresting,
			isSkippable: false,
			nodes: nodes,
			geometry: geometry)
	}
	
	// A function for decoding a relation inside of a keyed container.
	private func decodeRelation(
		within container: KeyedDecodingContainer<ElementCodingKeys>) throws -> Relation
	{
		// Decode the way's id number
		let id = try container.decode(Int.self, forKey: .id)
		
		// If present, decode the tag dictionary that provides additional element details. Then check to see if any interesting tags are present. The isInteresting property is useful for determining whether or not to plot an element.
		let tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
		let isInteresting = TagChecker.checkForInterestingTags(amongstTags: tags)
		
		// Get the relation type 
		let relationType = tags[Overpass.Keys.type]
		
		// If center was specified as the output format, the center key will be present in the relation's JSON dictionary. If present, decode the relation's center.
		let center = try container.decodeIfPresent(ElementCenter.self, forKey: .center)
		let centerIsPresent = center != nil
		
		let isDisplayable: Bool
		
		// If the relation has a displayable type, set isDisplayable to true. This will be determine whether the relation should have an associated geometery.
		if let relationType = relationType {
			isDisplayable = Relation.displayableTypes.contains(relationType)
		} else {
			isDisplayable = false
		}
		
		// A relation is a collection of members. Members can be nodes, ways, or relations.
		var members: [Relation.Member]
		
		// A container that will be used to decode the relation's member array.
		var membersContainer = try container.nestedUnkeyedContainer(forKey: .members)
		
		if isDisplayable && !centerIsPresent {
			// If full geometry is required, decode members and generate their geometries.
			members = try decodeDisplayableRelationMembers(within: &membersContainer)
		} else {
			// Otherwise, decode the non-gemoetric data of the members only
			members = try decodeRelationMembers(within: &membersContainer)
		}
		
		// Generate an array of member ids.
		let memberIds = members.map { $0.id }
		
		// Initializing the geometry variable for the relation.
		let geometry: ElementGeometry
		
		// A relation's geometry is a multipolygon if it has one of the following types:
		let isMultiPolygon =
			relationType == Overpass.Values.multipolygon ||
				relationType == Overpass.Values.barrier
		
		if centerIsPresent {
			if isMultiPolygon {
				// If the output type is center and the relation type is multipolygon
				
				guard let center = center else {
					throw ElementDecodingError.unexpectedNil(elementId: id)
				}
				
				// Denote that each member is skippable, otherwise multiple annotations would correspond to the same object
				members.map { $0.id }.forEach { memberId in
					_elements[memberId]?.isSkippable = true
				}
				
				// Get the center coordinate from the decoded center object
				let coordinate = CLLocationCoordinate2D(
					latitude: center.latitude,
					longitude: center.longitude)
				
				// Set the geometry to center
				geometry = .center(coordinate)
				
			} else {
				// If the output type is center ut the relation isn't a multipolygon do not set any geometry
				geometry = .none
			}
		} else if isMultiPolygon {
			// If the relation is a multipolygon generate theappropriate geometry (an array of nested polygon coordinates)
			geometry = try generateMultiPolygonGeometry(fromMembers: members)
		} else if isDisplayable {
			// If the relation is displayable but not a multipolygon, it's geometry is a multipolyline
			geometry = try generateMultiPolylineGeometry(fromMembers: members)
		} else {
			// Otherwise, the relation should not have any geometry.
			geometry = .none
		}
		
		// Return the decoded relation
		return Relation(
			id: id,
			tags: tags,
			isInteresting: isInteresting,
			isSkippable: false,
			members: memberIds,
			geometry: geometry)
	}
	
	// Decode relation members w/o setting their geometries
	private func decodeRelationMembers(within container: inout UnkeyedDecodingContainer) throws -> [Relation.Member] {
		
		var members = [Relation.Member]()
		
		while !container.isAtEnd {
			
			// Use a keyed container to decode the id, type, and role of each relation member
			let memberContainer = try container.nestedContainer(keyedBy: Relation.Member.CodingKeys.self)
			let id = try memberContainer.decode(Int.self, forKey: .id)
			let type = try memberContainer.decode(ElementType.self, forKey: .type)
			let role = try memberContainer.decode(String.self, forKey: .role)
			
			// Generate the member object w/ an empty coordinate array
			let member = Relation.Member(
				type: type,
				id: id,
				role: role,
				coordinates: [])
			
			members.append(member)
		}
		
		return members
	}
	
	// Decode relations and set the geometry
	private func decodeDisplayableRelationMembers(within container: inout UnkeyedDecodingContainer) throws -> [Relation.Member] {
		
		var members = [Relation.Member]()
		
		while !container.isAtEnd {
			
			// Use a keyed container to decode the id, type, and role of each relation member
			let memberContainer = try container.nestedContainer(keyedBy: Relation.Member.CodingKeys.self)
			let id = try memberContainer.decode(Int.self, forKey: .id)
			let type = try memberContainer.decode(ElementType.self, forKey: .type)
			let role = try memberContainer.decode(String.self, forKey: .role)
			
			// Generate the geometries for each member
			let coordinates: [CLLocationCoordinate2D]
				
				// If the geometry output is specified, each member will contain an array of coordinates
				if let fullGeometry = try memberContainer.decodeIfPresent([[String: Double]].self, forKey: .geometry) {
					  
					// Map the coordinate array to an array of CLLocationCoordinate2d
					coordinates = fullGeometry.compactMap {
						guard
							let latitude = $0[Overpass.Keys.latitude],
							let longitude = $0[Overpass.Keys.longitude]
						else {
							return nil
						}
						return CLLocationCoordinate2D(
							latitude: latitude,
							longitude: longitude)
					}
					
					// If any coordiantes are missing after the conversion, disregard the member
					guard coordinates.count == fullGeometry.count else { continue }
					
				} else {
					//If the output isn't geometry or center, construct the geometries of member ways from previously decoded ways
					let id = try memberContainer.decode(Int.self, forKey: .id)
					
					// If the member is a way, set it's geometry
					guard let element = _elements[id] else {
						continue
					}
					
					// If the member is a way set, the geometry to the way's coordinates
					switch element.geometry {
					case .polygon(let wayCoordinates), .polyline(let wayCoordinates):
						coordinates = wayCoordinates
					default:
						coordinates = []
					}
				}
			
			// Generate a new member object with a full geometry if it is a way
			let member = Relation.Member(
				type: type,
				id: id,
				role: role,
				coordinates: coordinates)
			
			members.append(member)
		}
		
		// Return all members
		return members
	}
	
	// Generate the geometry for multipolygons
	private func generateMultiPolygonGeometry(
		fromMembers members: [Relation.Member]) throws -> ElementGeometry
	{
		
		// Get the inner and out member ways
		let memberWays = members.filter { $0.type == .way }
		let outerWays = memberWays.filter { $0.role == Overpass.Values.outer }
		let innerWays = memberWays.filter { $0.role == Overpass.Values.inner }
		 
		// Get an array where each element is a member way's coordinates
		let outerCoordinateArrays = outerWays.map { $0.coordinates }
		let innerCoordinateArrays = innerWays.map { $0.coordinates }
		
		// Merge the ways with matching end coordinates
		let mergedOuterWays = merge(coordinateArrays: outerCoordinateArrays)
		let mergedInnerWays = merge(coordinateArrays: innerCoordinateArrays)
		
		// Match inner ways with outer ways. An outer way can have any number of inner ways
		let geometries = assembleNestedGeometries(
			outerGeometries: mergedOuterWays,
			innerGeometries: mergedInnerWays)
		
		// If a multipolygon contains to ways, than it has no geometry
		guard !geometries.isEmpty else {
			throw ElementDecodingError.emptyRelation
		}
		
		// Denote that the outer and inner ways of the multipolygon are skippable so they are not rendered individually in addition to being rendered as a multipolygon.
		outerWays.forEach {
			_elements[$0.id]?.isSkippable = true
		}
		
		innerWays.forEach {
			_elements[$0.id]?.isSkippable = true
		}
		
		// return the geometry
		return .multiPolygon(geometries)
	}
	
	// Generate the geometry for multipolylines
	private func generateMultiPolylineGeometry(
		fromMembers members: [Relation.Member]) throws -> ElementGeometry
	{
		// Filter out members for ways only and assemble an array where each element is a member way's coordinates
		let memberWays = members.filter { $0.type == .way }
		let wayGeometries = memberWays.map { $0.coordinates }
		
		// Merge ways with matching end coordinates
		let mergedWayGeometries = merge(coordinateArrays: wayGeometries)
		
		guard !mergedWayGeometries.isEmpty else {
			throw ElementDecodingError.emptyRelation
		}
		
		// Interesting ways can be rendered individually. Uninteresting ways are skippable if already rendered by the mulipolyline
		memberWays.forEach {
			if _elements[$0.id]?.isInteresting != true {
				_elements[$0.id]?.isSkippable = true
			}
		}
		
		// Return the multipolyline
		return .multiPolyline(mergedWayGeometries)
	}
	
	// Merge ways end to end to form larger geometries
	private func merge(coordinateArrays: [[CLLocationCoordinate2D]]) -> [[CLLocationCoordinate2D]] {
		
		var geometries = coordinateArrays // Initial unmerged way geometries
		var mergedGeometries = [[CLLocationCoordinate2D]]() // Array for storing merged geometries
		
		while true {
			
			// Pop the last unmerged geometry from the geometries array. We will attempt to merge additional geometries to it
			guard var mergedGeometry = geometries.popLast() else {
				break
			}
			
			// Get the first and last coordinate of the base geometry that we are merging onto
			guard
				let mergedFirst = mergedGeometry.first,
				let mergedLast = mergedGeometry.last
			else {
				continue
			}
			
			// If there are geometries available to merge to our base geometry and if our base geometry is not already a close loop of coordinates...
			while !geometries.isEmpty || mergedFirst.isEqual(to: mergedLast) {
				
				// Get the length prior to merging
				let mergedLength = mergedGeometry.count
				
				// Check unmerged arrays to see if any have matching ends with out base geometry
				for (index, currentGeometry) in geometries.enumerated() {
					
					// Get the endpoints for the geometry we are attempting to mergo to our base
					guard
						let currentFirst = currentGeometry.first,
						let currentLast = currentGeometry.last
					else {
						continue
					}
					
					if mergedLast.isEqual(to: currentFirst) {
						// If the last coordinate of the first geometry matches the the first coordinate of second geometry, merge the two arrays without doing any preprocessing
						mergedGeometry.removeLast()
						mergedGeometry.append(contentsOf: geometries.remove(at: index))
						break
					} else if mergedLast.isEqual(to: currentLast) {
						// If the the last coordinate of the first geometry matches the last coordinate of the second geometry, reverse the second geometry and merge the coordinate arrays.
						mergedGeometry.removeLast()
						mergedGeometry.append(contentsOf: geometries.remove(at: index).reversed())
						break
					} else if mergedFirst.isEqual(to: currentLast) {
						// If the first element of the first geometry matches the last element of the second geometry, append the second geometry to the start of the first geometry.
						var arrayToAdd = geometries.remove(at: index)
						arrayToAdd.removeLast()
						mergedGeometry.insert(contentsOf: arrayToAdd, at: 0)
						break
					} else if mergedFirst.isEqual(to: currentFirst) {
						// If the first element of the first geometry matches the first element of the second geometry, reverse the second geometry and appent it to the front of the first geometry.
						var arrayToAdd = geometries.remove(at: index)
						arrayToAdd.reverse()
						arrayToAdd.removeLast()
						mergedGeometry.insert(contentsOf: arrayToAdd, at: 0)
						break
					}
				}
				
				// If no geometries were able to be merged to our base geometry, break and start over with another base geometry. If we were able to grow our base geometry to a meger, attempt to merge additional geometries onto our base geometry until no matches can be found or the base geometry forms a closed loop.
				if mergedLength == mergedGeometry.count {
					break
				}
			}
			
			// Append a geometry to the merged geometries output array once no more mergers can be made to it.
			mergedGeometries.append(mergedGeometry)
		}
		
		//output the merged geometries
		return mergedGeometries
	}
	
	// A function that matches inner geometries with outer geometries by determining whether or not an inner geometry has a coordinate that exists within any of the supplied outer geometries.
	private func assembleNestedGeometries(
		outerGeometries: [[CLLocationCoordinate2D]],
		innerGeometries: [[CLLocationCoordinate2D]]) -> [NestedPolygonCoordinates]
	{
		// Filter out any outer geometries that do not form a closed loop
		let outerRings = outerGeometries.filter {
			guard
				let firstCoordinate = $0.first,
				let lastCoordinate = $0.last
			else {
				return false
			}
			return firstCoordinate.isEqual(to: lastCoordinate)
			
		}
		
		// Filter out any inner geometries that do not form a closed loop
		let innerRings = innerGeometries.filter {
			guard
				let firstCoordinate = $0.first,
				let lastCoordinate = $0.last
			else {
				return false
			}
			return firstCoordinate.isEqual(to: lastCoordinate)
			
		}
		
		// Initialize an array of nested polygons in coordinate form
		var geometries = [NestedPolygonCoordinates]()
		
		// Intilialize a set for tracking which inner geometries have already been matched to an outer geometry
		var consumedInnerGeometryIndices = Set<Int>()
		
		// For each outer ring of coordinates
		for outer in outerRings {
			
			// Initialize an array of inner rings that match with that outer ring
			var innersForOuter = [[CLLocationCoordinate2D]]()
			
			// For each inner array
			for (index, inner) in innerRings.enumerated() {
				
				// If it has not already been matched with an outer ring
				guard !consumedInnerGeometryIndices.contains(index) else {
					continue
				}
				
				// If the inner ring is empty consume it without adding it to an outer ring
				guard
					let coordinate = inner.first
				else {
					consumedInnerGeometryIndices.insert(index)
					continue
				}
				
				// Check to see if the inner ring has a coordinate within the current outer ring. If true, consume the inner ring and append it to the inner rings array for the current outer ring.
				if checkForCoordinate(coordinate, inPolygonFormedByCoordinates: outer) {
					innersForOuter.append(inner)
					consumedInnerGeometryIndices.insert(index)
				}
			}
			
			// Create a nested polygon coordinates object from the current outer ring and any inner rings that it contains
			let nestedGeometry = NestedPolygonCoordinates(
			outerRing: outer,
			innerRings: innersForOuter)
			
			// append it to the nested geometry array
			geometries.append(nestedGeometry)
		}
		
		// return all nested geometries
		return geometries
	}
	
	// Ray casting algroithm to determine whether or not a coordinate is found withing a polygon whose vertices are formed by an array of polygon coordinates. If a line formed between the coordiante of interest and any point outside the polygon intersects with the polygon's perimeter an odd number of times then it is within the polygon.
	private func checkForCoordinate(
		_ c: CLLocationCoordinate2D,
		inPolygonFormedByCoordinates polygonCoordinates: [CLLocationCoordinate2D]) -> Bool
	{
		var isInside = false
		
		for index in 0..<(polygonCoordinates.count - 1) {
			let c1 = polygonCoordinates[index]
			let c2 = polygonCoordinates[index + 1]
			
			if
				((c1.latitude > c.latitude) != (c2.latitude > c.latitude)) &&
				(c.longitude < (c2.longitude - c1.longitude) * (c.latitude - c1.longitude) / (c2.latitude - c1.latitude) + c1.longitude)
			{
				isInside = !isInside
			}
		}
		return isInside
	}
}


