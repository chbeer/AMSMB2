//
//  AMSMB2.swift
//  AMSMB2
//
//  Created by Amir Abbas Mousavian.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//

import Foundation
import SMB2

public typealias SimpleCompletionHandler = ((_ error: Error?) -> Void)?

/// Implements SMB2 File operations.
@objc
public class AMSMB2: NSObject {
    fileprivate var context: SMB2Context
    private let url: SMB2URL
    private let _user: String
    private let _server: String
    private let q: DispatchQueue
    
    /**
     Initializes a SMB2 class with given url and credential.
     
     - Note: For now, only user/password credential on NTLM servers are supported.
     
     - Important: A connection to a share must be established by connectShare(name:completionHandler:) before any operation.
     */
    @objc
    public init?(url: URL, domain: String = "", credential: URLCredential?) {
        guard let context = SMB2Context(), let smburl = SMB2URL(url.absoluteString, on: context), let host = url.host else {
            return nil
        }
        
        self.context = context
        self.url = smburl
        let hostLabel = url.host.map({ "_" + $0 }) ?? ""
        self.q = DispatchQueue(label: "smb2_queue\(hostLabel)", qos: .default, attributes: [])
        context.set(securityMode: .enabled)
        
        var workstation: String = ""
        var user: String = "guest"
        if let userComps = credential?.user?.components(separatedBy: "\\") {
            switch userComps.count {
            case 1:
                user = userComps[0]
            case 2:
                workstation = userComps[0]
                user = userComps[1]
            default:
                if let u_user = smburl.user {
                    user = u_user
                }
            }
        } else {
            if let u_user = smburl.user {
                user = u_user
            }
        }
        _server = host
        context.set(domain: domain)
        context.set(workstation: workstation)
        context.set(user: user)
        _user = user
        context.set(password: credential?.password ?? "")
    }
    
    /**
     Connects to a share.
     */
    @objc
    public func connectShare(name: String, completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                let server = self.url.server ?? self._server
                try self.context.connect(server: server, share: name, user: self._user)
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Disconnects from a share.
     */
    @objc
    public func disconnectShare(completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                try self.context.disconnect()
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Enumerates directory contents in the give path
     
     - Parameters:
       - atPath: path of directory to be enumerated.
       - completionHandler: closure will be run after enumerating is completed.
       - recursive: subdirectories will enumerated if `true`.
       - contents: An array of `[URLResourceKey: Any]` which holds files' attributes. file name is stored in `.nameKey`.
       - error: `Error` if any occured during enumeration.
     */
    @objc
    public func contentOfDirectory(atPath path: String, recursive: Bool = false,
                                   completionHandler: @escaping (_ contents: [[URLResourceKey: Any]], _ error: Error?) -> Void) {
        q.async {
            do {
                let contents = try self.listDirectory(path: path, recursive: recursive)
                completionHandler(contents, nil)
            } catch {
                completionHandler([], error)
            }
        }
    }
    
    @objc
    public func attributesOfFileSystem(forPath path: String,
                                       completionHandler: @escaping (_ attrubutes: [FileAttributeKey: Any]?, _ error: Error?) -> Void) {
        q.async {
            do {
                let stat = try self.context.statvfs(path)
                var result = [FileAttributeKey: Any]()
                let blockSize = UInt64(stat.f_bsize)
                result[.systemNumber] = NSNumber(value: UInt64(stat.f_fsid))
                if stat.f_blocks < UInt64.max / blockSize {
                    result[.systemSize] = NSNumber(value: blockSize * UInt64(stat.f_blocks))
                    result[.systemFreeSize] = NSNumber(value: blockSize * UInt64(stat.f_bavail))
                }
                result[.systemNodes] = NSNumber(value: UInt64(stat.f_files))
                result[.systemFreeNodes] = NSNumber(value: UInt64(stat.f_ffree))
                completionHandler(result, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }
    
    /**
     Returns the attributes of the item at given path.
     
     - Parameters:
       - atPath: path of file to be enumerated.
       - completionHandler: closure will be run after enumerating is completed.
       - file: An dictionary with `URLResourceKey` as key which holds file's attributes.
       - error: `Error` if any occured during enumeration.
     */
    @objc
    public func attributesOfItem(atPath path: String,
                                 completionHandler: @escaping (_ file: [URLResourceKey: Any]?, _ error: Error?) -> Void) {
        q.async {
            do {
                let stat = try self.context.stat(path)
                var result = [URLResourceKey: Any]()
                let name = NSString(string: (path as NSString).lastPathComponent)
                result[.nameKey] = name
                result[.pathKey] = (path as NSString).appendingPathComponent(name as String)
                self.populateResourceValue(&result, stat: stat)
                completionHandler(result, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }
    
    /**
     Creates a new directory at given path.
     
     - Parameters:
       - atPath: path of new directory to be created.
       - completionHandler: closure will be run after operation is completed.
     */
    @objc
    public func createDirectory(atPath path: String, completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                try self.context.mkdir(path)
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Removes an existing directory at given path.
     
     - Parameters:
       - atPath: path of directory to be removed.
       - recursive: children items will be deleted if `true`.
       - completionHandler: closure will be run after operation is completed.
     */
    @objc
    public func removeDirectory(atPath path: String, recursive: Bool, completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                if recursive {
                    let list = try self.listDirectory(path: path, recursive: true)
                    let sortedContents = list.sorted(by: {
                        guard let firstPath = $0.filepath, let secPath = $1.filepath else {
                            return false
                        }
                        return firstPath.localizedStandardCompare(secPath) == .orderedDescending
                    })
                    
                    for item in sortedContents {
                        guard let itemPath = item.filepath else { continue }
                        if item.filetype == URLFileResourceType.directory {
                            try self.context.rmdir(itemPath)
                        } else {
                            try self.context.unlink(itemPath)
                        }
                    }
                }
                
                try self.context.rmdir(path)
                
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Removes an existing file at given path.
     
     - Parameters:
       - atPath: path of file to be removed.
       - completionHandler: closure will be run after operation is completed.
     */
    @objc
    public func removeFile(atPath path: String, completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                try self.context.unlink(path)
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Truncates or extends the file represented by the path to a specified offset within the file and
     puts the file pointer at that position.
     
     If the file is extended (if offset is beyond the current end of file), the added characters are null bytes.
     
     - Parameters:
       - atPath: path of file to be truncated.
       - completionHandler: closure will be run after operation is completed.
     */
    @objc
    public func truncateFile(atPath path: String, atOffset: UInt64, completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                try self.context.truncate(path, toLength: atOffset)
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Moves/Renames an existing file at given path to a new location.
     
     - Parameters:
       - atPath: path of file to be move.
       - toPath: new location of file.
       - completionHandler: closure will be run after operation is completed.
     */
    @objc
    public func moveItem(atPath path: String, toPath: String, completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                try self.context.rename(path, to: toPath)
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Fetches data contents of a file from an offset with specified length. With reporting progress
     on about every 64KB.
     
     - Note: If offset is bigger than file's size, an empty `Data will be returned. If length exceeds file, returned data
         will be truncated to entire file content from given offset.
     
     - Parameters:
       - atPath: path of file to be fetched.
       - offset: first byte of file to be read, starting from zero.
       - length: length of bytes should be read from offset. If a value.
       - progress: reports progress of recieved bytes count read and expected content length.
           User must return `true` if they want to continuing or `false` to abort reading.
       - bytes: recieved bytes count.
       - total: expected content length.
       - completionHandler: closure will be run after reading data is completed.
       - contents: a `Data` object which contains file contents.
       - error: `Error` if any occured during reading.
     */
    @objc
    public func contents(atPath path: String, offset: Int64 = 0, length: Int = -2,
                         progress: ((_ bytes: Int64, _ total: Int64) -> Bool)?,
                         completionHandler: @escaping (_ contents: Data?, _ error: Error?) -> Void) {
        q.async {
            do {
                let file = try SMB2FileHanle(forReadingAtPath: path, on: self.context)
                let filesize = try Int64(file.fstat().smb2_size)
                let size = min(Int64(length), filesize - offset)
                
                var offset = offset
                var result = Data()
                var eof = false
                guard try file.lseek(offset: offset) == offset else {
                    throw POSIXError(.EOVERFLOW)
                }
                while !eof {
                    let data = try file.read()
                    result.append(data)
                    offset += Int64(data.count)
                    let shouldContinue = progress?(offset, size) ?? true
                    eof = !shouldContinue || data.isEmpty || (length > 0 && result.count > length)
                }
                
                completionHandler(result.prefix(length), nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }
    
    /**
     Streams data contents of a file from an offset with specified length. With reporting data and progress
     on about every 64KB.
     
     - Parameters:
       - atPath: path of file to be fetched.
       - offset: first byte of file to be read, starting from zero.
       - fetchedData: returns data portion fetched and recieved bytes count read and expected content length.
           User must return `true` if they want to continuing or `false` to abort reading.
       - offset: offset of first byte of data portion in file.
       - total: expected content length.
       - data: data portion which read from server.
       - completionHandler: closure will be run after reading data is completed.
     */
    @objc
    public func contents(atPath path: String, offset: Int64 = 0,
                         fetchedData: @escaping ((_ offset: Int64, _ total: Int64, _ data: Data) -> Bool),
                         completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                let file = try SMB2FileHanle(forReadingAtPath: path, on: self.context)
                let size = try Int64(file.fstat().smb2_size)
                
                var offset = offset
                var eof = false
                guard try file.lseek(offset: offset) == offset else {
                    throw POSIXError(.EOVERFLOW)
                }
                while !eof {
                    let data = try file.read()
                    if data.isEmpty {
                        break
                    }
                    let shouldContinue = fetchedData(offset, size, data)
                    offset += Int64(data.count)
                    eof = !shouldContinue || data.isEmpty
                }
                
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Creates and writes data to file. With reporting progress on about every 64KB.
     
     - Note: Data saved in server maybe truncated of completion handler returns error.
     
     - Parameters:
       - data: data that must be written to file.
       - atPath: path of file to be written.
       - progress: reports progress of written bytes count so far.
           User must return `true` if they want to continuing or `false` to abort writing.
       - bytes: written bytes count.
       - completionHandler: closure will be run after writing is completed.
     */
    @objc
    public func write(data: Data, toPath path: String, progress: ((_ bytes: Int64) -> Bool)?,
                      completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                let file = try SMB2FileHanle(forCreatingAndWritingAtPath: path, on: self.context)
                
                var offset: Int64 = 0
                while true {
                    let segment = data[offset...].prefix(file.optimizedWriteSize)
                    if segment.count == 0 {
                        break
                    }
                    let written = try file.write(data: segment)
                    offset += Int64(written)
                    if let shouldContinue = progress?(offset), !shouldContinue {
                        break
                    }
                }
                try file.fsync()
                
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Copy file contents to a new location. With reporting progress on about every 64KB.
     
     - Note: This operation consists downloading and uploading file, which may take bandwidth.
     Unfortunately there is not a way to copy file remotely right now.
     
     - Parameters:
       - atPath: path of file to be copied from.
       - toPath: path of new file to be copied to.
       - recursive: copies directory structure and files if path is directory.
       - progress: reports progress of written bytes count so far and expected length of contents.
           User must return `true` if they want to continuing or `false` to abort copying.
       - bytes: written bytes count.
       - completionHandler: closure will be run after copying is completed.
     */
    @objc
    public func copyContentsOfItem(atPath path: String, toPath: String, recursive: Bool,
                                   progress: ((_ bytes: Int64, _ total: Int64) -> Bool)?,
                                   completionHandler: SimpleCompletionHandler) {
        q.async {
            do {
                let stat = try self.context.stat(path)
                if stat.smb2_type == SMB2_TYPE_DIRECTORY {
                    try self.context.mkdir(toPath)
                    
                    let list = try self.listDirectory(path: path, recursive: true)
                    let sortedContents = list.sorted(by: {
                        guard let firstPath = $0.filepath, let secPath = $1.filepath else {
                            return false
                        }
                        return firstPath.localizedStandardCompare(secPath) == .orderedAscending
                    })
                    
                    let overallSize = list.reduce(0, { (result, value) -> Int64 in
                        if value.filetype  == URLFileResourceType.regular {
                            return result + (value.filesize ?? 0)
                        } else {
                            return result
                        }
                    })
                    
                    var totalCopied: Int64 = 0
                    for item in sortedContents {
                        guard let itemPath = item.filepath else { continue }
                        let destPath = itemPath.replacingOccurrences(of: path, with: toPath, options: .anchored)
                        if item.filetype == URLFileResourceType.directory {
                            try self.context.mkdir(destPath)
                        } else {
                            let shouldContinue = try self.copyContentsOfFile(atPath: itemPath, toPath: destPath, progress: {
                                (written, _) -> Bool in
                                totalCopied += written
                                return progress?(totalCopied, overallSize) ?? true
                            })
                            if !shouldContinue {
                                break
                            }
                        }
                    }
                } else {
                    _ = try self.copyContentsOfFile(atPath: path, toPath: toPath, progress: progress)
                }
                
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Uploads local file contents to a new location. With reporting progress on about every 64KB.
     
     - Note: given url must be local file url otherwise process will crash.
     
     - Parameters:
     - at: url of a local file to be uploaded from.
     - toPath: path of new file to be uploaded to.
     - progress: reports progress of written bytes count so far.
         User must return `true` if they want to continuing or `false` to abort copying.
     - completionHandler: closure will be run after uploading is completed.
     */
    @objc
    public func uploadItem(at url: URL, toPath: String, progress: ((_ bytes: Int64) -> Bool)?,
                           completionHandler: SimpleCompletionHandler) {
        guard url.isFileURL else {
            fatalError("Uploading to remote url is not supported.")
        }
        
        q.async {
            do {
                if try !url.checkResourceIsReachable() {
                    throw POSIXError(.EIO)
                }
                
                let localHandle = try FileHandle(forReadingFrom: url)
                localHandle.seek(toFileOffset: 0)
                
                
                let file = try SMB2FileHanle(forCreatingAndWritingAtPath: toPath, on: self.context)
                
                var offset: Int64 = 0
                while true {
                    if localHandle.offsetInFile != offset {
                        localHandle.seek(toFileOffset: UInt64(offset))
                    }
                    
                    let segment = localHandle.readData(ofLength: file.optimizedWriteSize)
                    if segment.count == 0 {
                        break
                    }
                    let written = try file.write(data: segment)
                    offset += Int64(written)
                    if let shouldContinue = progress?(offset), !shouldContinue {
                        break
                    }
                }
                try file.fsync()
                
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }
    
    /**
     Downloads file contents to a local url. With reporting progress on about every 64KB.
     
     - Note: if a file already exists on given url, This function will overwrite to that url.
     
      Note: given url must be local file url otherwise process will crash.
     
     - Parameters:
     - atPath: path of file to be downloaded from.
     - at: url of a local file to be written to.
     - progress: reports progress of written bytes count so farand expected length of contents.
         User must return `true` if they want to continuing or `false` to abort copying.
     - completionHandler: closure will be run after uploading is completed.
     */
    @objc
    public func downloadItem(atPath path: String, to url: URL,
                             progress: ((_ bytes: Int64, _ total: Int64) -> Bool)?,
                             completionHandler: SimpleCompletionHandler) {
        guard url.isFileURL else {
            fatalError("Downloading to remote url is not supported.")
        }
        
        q.async {
            do {
                let file = try SMB2FileHanle(forReadingAtPath: path, on: self.context)
                let size = try Int64(file.fstat().smb2_size)
                
                if (try? url.checkResourceIsReachable()) ?? false {
                    try? FileManager.default.removeItem(at: url)
                    try Data().write(to: url)
                } else {
                    try Data().write(to: url)
                }
                
                let localHandle = try FileHandle(forWritingTo: url)
                var offset: Int64 = 0
                var eof = false
                while !eof {
                    let data = try file.read()
                    localHandle.write(data)
                    offset += Int64(data.count)
                    let shouldContinue = progress?(offset, size) ?? true
                    eof = !shouldContinue || data.isEmpty
                }
                localHandle.synchronizeFile()
                completionHandler?(nil)
            } catch {
                try? FileManager.default.removeItem(at: url)
                completionHandler?(error)
            }
        }
    }
}

extension AMSMB2 {
    fileprivate func populateResourceValue(_ dic: inout [URLResourceKey: Any], stat: smb2_stat_64) {
        dic[.fileSizeKey] = NSNumber(value: stat.smb2_size)
        dic[.fileResourceTypeKey] = stat.smb2_type == SMB2_TYPE_DIRECTORY ? URLFileResourceType.directory : URLFileResourceType.regular
        let modified = TimeInterval(stat.smb2_mtime) + TimeInterval(stat.smb2_mtime_nsec) / TimeInterval(NSEC_PER_SEC)
        dic[.contentModificationDateKey] = NSDate(timeIntervalSince1970: modified)
        let created = TimeInterval(stat.smb2_ctime) + TimeInterval(stat.smb2_ctime_nsec) / TimeInterval(NSEC_PER_SEC)
        dic[.contentModificationDateKey] = NSDate(timeIntervalSince1970: created)
    }
    
    fileprivate func listDirectory(path: String, recursive: Bool) throws -> [[URLResourceKey: Any]] {
        var contents = [[URLResourceKey: Any]]()
        let dir = try SMB2Directory(path, on: self.context)
        for ent in dir {
            let name = NSString(utf8String: ent.name)
            if [".", ".."].contains(name) { continue }
            var result = [URLResourceKey: Any]()
            result[.nameKey] = name
            result[.pathKey] = name.map { (path as NSString).appendingPathComponent($0 as String) }
            self.populateResourceValue(&result, stat: ent.st)
            contents.append(result)
        }
        
        if recursive {
            let subDirectories = contents.filter { $0.filetype == .directory }
            
            for subDir in subDirectories {
                guard let path = subDir.filepath else { continue }
                contents.append(contentsOf: try listDirectory(path: path, recursive: true))
            }
        }
        
        return contents
    }
    
    private func copyContentsOfFile(atPath path: String, toPath: String,
                                    progress: ((_ bytes: Int64, _ total: Int64) -> Bool)?) throws -> Bool {
        let fileRead = try SMB2FileHanle(forReadingAtPath: path, on: self.context)
        let size = try Int64(fileRead.fstat().smb2_size)
        let fileWrite = try SMB2FileHanle(forCreatingAndWritingAtPath: toPath, on: self.context)
        var offset: Int64 = 0
        var eof = false
        var shouldContinue = true
        while !eof {
            let data = try fileRead.read()
            let written = try fileWrite.write(data: data)
            offset += Int64(written)
            
            shouldContinue = progress?(offset, size) ?? true
            eof = !shouldContinue || data.isEmpty
        }
        try fileWrite.fsync()
        return shouldContinue
    }
}
