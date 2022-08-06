//
//  AbsDownloader.swift
//  App
//
//  Created by advplyr on 5/13/22.
//

import Foundation
import Capacitor

@objc(AbsDownloader)
public class AbsDownloader: CAPPlugin, URLSessionDownloadDelegate {
    
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .current)
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        NSLog("Finished downloading \(downloadTask.taskDescription ?? "Unknown Task")")
        
        guard let downloadItemPartId = downloadTask.taskDescription else { return }
        
        let downloadItem = Database.shared.getDownloadItem(downloadItemPartId: downloadItemPartId)
        guard let downloadItem = downloadItem else {
            NSLog("Download item part (%@) not found! Unable to move file!", downloadItemPartId)
            return
        }
        
        NSLog("Found downloadItem(%@)", downloadItem.id)
        self.moveLibraryItemToFileDirectory(tempUrl: location)
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        NSLog("Error downloading \(task.taskDescription ?? "Unknown Task"): \(error ?? "Unknown Error")")
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Find the download item
        guard let downloadItemPartId = downloadTask.taskDescription else { return }
        let downloadItem = Database.shared.getDownloadItem(downloadItemPartId: downloadItemPartId)
        guard let downloadItem = downloadItem else {
            NSLog("Download item part (%@) not found!", downloadItemPartId)
            return
        }
        
        // Calculate the download percentage
        let percentDownloaded = (Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100
        NSLog("Received download status \(downloadItemPartId): \(percentDownloaded)")
        Database.shared.updateDownloadItemPartPercent(downloadItemPartId: downloadItemPartId, percent: percentDownloaded)
        let downloadItemPart = downloadItem.downloadItemParts.filter { part in
            part.id == downloadItemPartId
        }.first
        
        // Notify the UI
        NSLog("Download progress: \(downloadItemPart?.progress ?? 0)")
        try! notifyListeners("onItemDownloadUpdate", data: downloadItem.asDictionary())
    }
    
    @objc func downloadLibraryItem(_ call: CAPPluginCall) {
        let libraryItemId = call.getString("libraryItemId")
        let episodeId = call.getString("episodeId")
        
        NSLog("Download library item \(libraryItemId ?? "N/A") / episode \(episodeId ?? "")")
        guard let libraryItemId = libraryItemId else { call.resolve(); return; }
        
        ApiClient.getLibraryItemWithProgress(libraryItemId: libraryItemId, episodeId: episodeId) { libraryItem in
            if (libraryItem == nil) {
                NSLog("Library item not found")
                call.resolve(["error": "Library item not found"])
            } else {
                NSLog("Got library item from server \(libraryItem!.id)")
                do {
                    try self.startLibraryItemDownload(libraryItem!)
                    call.resolve()
                } catch {
                    NSLog("Failed to download \(error)")
                    call.resolve(["error": "Failed to download"])
                }
            }
        }
    }
    
    private func startLibraryItemDownload(_ item: LibraryItem) throws {
        guard let tracks = item.media.tracks else {
            throw LibraryItemDownloadError.noTracks
        }
        
        // Queue up everything for downloading
        var downloadItem = DownloadItem(libraryItem: item, server: Store.serverConfig!)
        downloadItem.downloadItemParts = try tracks.enumerated().map({ i, track in
            try startLibraryItemTrackDownload(item: item, position: i, track: track)
        })
        
        // Persist in the database before status start coming in
        Database.shared.saveDownloadItem(downloadItem)
        
        // Start all the downloads
        for downloadItemPart in downloadItem.downloadItemParts {
            downloadItemPart.task.resume()
        }
    }
    
    private func startLibraryItemTrackDownload(item: LibraryItem, position: Int, track: AudioTrack) throws -> DownloadItemPart {
        NSLog("TRACK \(track.contentUrl!)")
        
        // If we don't name metadata, then we can't proceed
        guard let filename = track.metadata?.filename else {
            throw LibraryItemDownloadError.noMetadata
        }
        
        let serverUrl = urlForTrack(item: item, track: track)
        let itemDirectory = try createLibraryItemFileDirectory(item: item)
        let localUrl = itemDirectory.appendingPathComponent("\(filename)")
        
        let task = session.downloadTask(with: serverUrl)
        var downloadItemPart = DownloadItemPart(filename: filename, destination: localUrl, itemTitle: track.title ?? "Unknown", serverPath: Store.serverConfig!.address, audioTrack: track, episode: nil)
        
        // Store the id on the task so the download item can be pulled from the database later
        task.taskDescription = downloadItemPart.id
        downloadItemPart.task = task
        
        return downloadItemPart
    }
    
    private func urlForTrack(item: LibraryItem, track: AudioTrack) -> URL {
        // filename needs to be encoded otherwise would just use contentUrl
        let filenameEncoded = track.metadata?.filename.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.urlQueryAllowed)
        let urlstr = "\(Store.serverConfig!.address)/s/item/\(item.id)/\(filenameEncoded ?? "")?token=\(Store.serverConfig!.token)"
        return URL(string: urlstr)!
    }
    
    private func createLibraryItemFileDirectory(item: LibraryItem) throws -> URL {
        let itemDirectory = documentsDirectory.appendingPathComponent("\(item.id)")
        NSLog("ITEM DIR \(itemDirectory)")
        
        do {
            try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Failed to CREATE LI DIRECTORY \(error)")
            throw LibraryItemDownloadError.failedDirectory
        }
        
        return itemDirectory
    }
    
    private func moveLibraryItemToFileDirectory(tempUrl: URL) {
        //try FileManager.default.moveItem(at: tempUrl, to: localUrl)
    }
    
}

enum LibraryItemDownloadError: String, Error {
    case noTracks = "No tracks on library item"
    case noMetadata = "No metadata for track, unable to download"
    case failedDirectory = "Failed to create directory"
    case failedDownload = "Failed to download item"
}
