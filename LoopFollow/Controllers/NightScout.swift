//
//  NightScout.swift
//  LoopFollow
//
//  Created by Jon Fawcett on 6/16/20.
//  Copyright © 2020 Jon Fawcett. All rights reserved.
//

import Foundation
import UIKit


extension MainViewController {
//
//    //NS BG Struct
//    struct sgvData: Codable {
//        var sgv: Int
//        var date: TimeInterval
//        var direction: String?
//    }
    
    //NS Cage Struct
    struct cageData: Codable {
        var created_at: String
    }
    
    //NS Basal Profile Struct
    struct basalProfileStruct: Codable {
        var value: Double
        var time: String
        var timeAsSeconds: Double
    }
    
    //NS Basal Data  Struct
    struct basalGraphStruct: Codable {
        var basalRate: Double
        var date: TimeInterval
    }
    
    //NS Bolus Data  Struct
    struct bolusCarbGraphStruct: Codable {
        var value: Double
        var date: TimeInterval
        var sgv: Int
    }
    
    
    // Main loader for all data
    func nightscoutLoader(forceLoad: Bool = false) {
        
        var needsLoaded: Bool = false
        var staleData: Bool = false
        var onlyPullLastRecord = false
        
        // If we have existing data and it's within 5 minutes, we aren't going to do a BG network call
        // if we have stale BG data 10 min or older, we're only going to attempt to pull BG and Loop status
        // to not have a full refresh every 15 seconds. The remaining data will start pulling again on the
        // next BG reading that comes in.
        if bgData.count > 0 {
            let now = NSDate().timeIntervalSince1970
            let lastReadingTime = bgData[bgData.count - 1].date
            let secondsAgo = now - lastReadingTime
            if secondsAgo >= 5*60 {
                needsLoaded = true
                if secondsAgo < 10*60 {
                    onlyPullLastRecord = true
                } else {
                    staleData = true
                }
            }
        } else {
            needsLoaded = true
        }
        
        
        if forceLoad { needsLoaded = true}
        // Only update if we don't have a current reading or forced to load
        if needsLoaded {
            self.clearLastInfoData()
            webLoadNSDeviceStatus()
            webLoadNSBGData(onlyPullLastRecord: onlyPullLastRecord)
            
            if !staleData {
                webLoadNSProfile()
                if UserDefaultsRepository.downloadBasal.value {
                    WebLoadNSTempBasals()
                }
                if UserDefaultsRepository.downloadBolus.value {
                    webLoadNSBoluses()
                }
                if UserDefaultsRepository.downloadCarbs.value {
                    webLoadNSCarbs()
                }
                webLoadNSCage()
                webLoadNSSage()
            }
            
            
            // Give the alarms and calendar 15 seconds delay to allow time for data to compile
            print("Start View Timer")
            self.startViewTimer(time: viewTimeInterval)
        } else {
            // Things to do if we already have data and don't need a network call
            // Leaving all downloads off for right now.
            /*
             webLoadNSDeviceStatus()
             
             if UserDefaultsRepository.downloadBolus.value {
                webLoadNSBoluses()
             }
             if UserDefaultsRepository.downloadCarbs.value {
                webLoadNSCarbs()
             }*/
            if bgData.count > 0 {
                self.checkAlarms(bgs: bgData)
            }
            
        }
    }
    
    // NS BG Data Web call
    func webLoadNSBGData(onlyPullLastRecord: Bool = false) {
        print("Enter BG Web Call")
        // Set the count= in the url either to pull 24 hours or only the last record
        var points = "1"
        if !onlyPullLastRecord {
            points = String(self.graphHours * 12 + 1)
        }
        
        // URL processor
        var urlBGDataPath: String = UserDefaultsRepository.url.value + "/api/v1/entries/sgv.json?"
        if token == "" {
            urlBGDataPath = urlBGDataPath + "count=" + points
        } else {
            urlBGDataPath = urlBGDataPath + "token=" + token + "&count=" + points
        }
        guard let urlBGData = URL(string: urlBGDataPath) else {
            
            return
            
        }
        var request = URLRequest(url: urlBGData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        
        // Downloader
        let getBGTask = URLSession.shared.dataTask(with: request) { data, response, error in
            if self.consoleLogging == true {print("start bg url")}
            guard error == nil else {
                return
                
            }
            guard let data = data else {
                return
                
            }
            
            let decoder = JSONDecoder()
            let entriesResponse = try? decoder.decode([DataStructs.sgvData].self, from: data)
            if let entriesResponse = entriesResponse {
                DispatchQueue.main.async {
                    // trigger the processor for the data after downloading.
                    self.ProcessNSBGData(data: entriesResponse, onlyPullLastRecord: onlyPullLastRecord)
                    
                }
            } else {
                return
                
            }
        }
        getBGTask.resume()
    }
    
    // NS BG Data Response processor
    func ProcessNSBGData(data: [DataStructs.sgvData], onlyPullLastRecord: Bool){
        print("Enter BG Processor")
        
        var pullDate = data[data.count - 1].date / 1000
        pullDate.round(FloatingPointRoundingRule.toNearestOrEven)
        
        // If we already have data, we're going to pop it to the end and remove the first. If we have old or no data, we'll destroy the whole array and start over. This is simpler than determining how far back we need to get new data from in case Dex back-filled readings
        if !onlyPullLastRecord {
            bgData.removeAll()
        } else if bgData[bgData.count - 1].date != pullDate {
            bgData.removeFirst()
            if data.count > 0 && UserDefaultsRepository.speakBG.value {
                speakBG(sgv: data[data.count - 1].sgv)
            }
        } else {
            if data.count > 0 {
                self.updateBadge(val: data[data.count - 1].sgv)
            }
            
            // self.viewUpdateNSBG()
            return
        }
        
        // loop through the data so we can reverse the order to oldest first for the graph and convert the NS timestamp to seconds instead of milliseconds. Makes date comparisons easier for everything else.
        for i in 0..<data.count{
            var dateString = data[data.count - 1 - i].date / 1000
            dateString.round(FloatingPointRoundingRule.toNearestOrEven)
            let reading = DataStructs.sgvData(sgv: data[data.count - 1 - i].sgv, date: dateString, direction: data[data.count - 1 - i].direction)
            bgData.append(reading)
        }
        
        viewUpdateNSBG()
    }
    
    // NS BG Data Front end updater
    func viewUpdateNSBG () {
        print("Enter BG View Update")
        guard let snoozer = self.tabBarController!.viewControllers?[2] as? SnoozeViewController else { return }
        let entries = bgData
        if entries.count > 0 {
            let latestEntryi = entries.count - 1
            let latestBG = entries[latestEntryi].sgv
            let priorBG = entries[latestEntryi - 1].sgv
            let deltaBG = latestBG - priorBG as Int
            let lastBGTime = entries[latestEntryi].date
            let deltaTime = (TimeInterval(Date().timeIntervalSince1970)-lastBGTime) / 60
            var userUnit = " mg/dL"
            if mmol {
                userUnit = " mmol/L"
            }
            
            BGText.text = bgUnits.toDisplayUnits(String(latestBG))
            snoozer.BGLabel.text = bgUnits.toDisplayUnits(String(latestBG))
            setBGTextColor()
            
            if let directionBG = entries[latestEntryi].direction {
                DirectionText.text = bgDirectionGraphic(directionBG)
                snoozer.DirectionLabel.text = bgDirectionGraphic(directionBG)
                latestDirectionString = bgDirectionGraphic(directionBG)
            }
            else
            {
                DirectionText.text = ""
                snoozer.DirectionLabel.text = ""
                latestDirectionString = ""
            }
            
            if deltaBG < 0 {
                self.DeltaText.text = bgUnits.toDisplayUnits(String(deltaBG))
                snoozer.DeltaLabel.text = bgUnits.toDisplayUnits(String(deltaBG))
                latestDeltaString = String(deltaBG)
            }
            else
            {
                self.DeltaText.text = "+" + bgUnits.toDisplayUnits(String(deltaBG))
                snoozer.DeltaLabel.text = "+" + bgUnits.toDisplayUnits(String(deltaBG))
                latestDeltaString = "+" + String(deltaBG)
            }
            self.updateBadge(val: latestBG)
            
        }
        else
        {
            
            return
        }
        updateBGGraph()
        updateMinAgo()
        updateStats()
    }
    
    // NS Device Status Web Call
    func webLoadNSDeviceStatus() {
        print("Enter download device status")
        let urlUser = UserDefaultsRepository.url.value
        var urlStringDeviceStatus = urlUser + "/api/v1/devicestatus.json?count=1"
        if token != "" {
            urlStringDeviceStatus = urlUser + "/api/v1/devicestatus.json?token=" + token + "&count=1"
        }
        let escapedAddress = urlStringDeviceStatus.addingPercentEncoding(withAllowedCharacters:NSCharacterSet.urlQueryAllowed)
        guard let urlDeviceStatus = URL(string: escapedAddress!) else {
            
            return
        }
        if consoleLogging == true {print("entered device status task.")}
        
        
        var requestDeviceStatus = URLRequest(url: urlDeviceStatus)
        requestDeviceStatus.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        
        
        let deviceStatusTask = URLSession.shared.dataTask(with: requestDeviceStatus) { data, response, error in
            if self.consoleLogging == true {print("in device status loop.")}
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            
            let json = try? (JSONSerialization.jsonObject(with: data) as! [[String:AnyObject]])
            if let json = json {
                DispatchQueue.main.async {
                    self.updateDeviceStatusDisplay(jsonDeviceStatus: json)
                }
            } else {
                return
            }
            if self.consoleLogging == true {print("finish pump update")}}
        deviceStatusTask.resume()
    }
    
    // NS Device Status Response Processor
    func updateDeviceStatusDisplay(jsonDeviceStatus: [[String:AnyObject]]) {
        print("Enter process device status")
        if consoleLogging == true {print("in updatePump")}
        if jsonDeviceStatus.count == 0 {
            return
        }
        
        //only grabbing one record since ns sorts by {created_at : -1}
        let lastDeviceStatus = jsonDeviceStatus[0] as [String : AnyObject]?
        
        //pump and uploader
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        if let lastPumpRecord = lastDeviceStatus?["pump"] as! [String : AnyObject]? {
            if let lastPumpTime = formatter.date(from: (lastPumpRecord["clock"] as! String))?.timeIntervalSince1970  {
                if let reservoirData = lastPumpRecord["reservoir"] as? Double {
                    tableData[5].value = String(format:"%.0f", reservoirData) + "U"
                } else {
                    tableData[5].value = "50+U"
                }
                
                if let uploader = lastDeviceStatus?["uploader"] as? [String:AnyObject] {
                    let upbat = uploader["battery"] as! Double
                    tableData[4].value = String(format:"%.0f", upbat) + "%"
                }
            }
        }
        
        // Loop
        if let lastLoopRecord = lastDeviceStatus?["loop"] as! [String : AnyObject]? {
            if let lastLoopTime = formatter.date(from: (lastLoopRecord["timestamp"] as! String))?.timeIntervalSince1970  {
                UserDefaultsRepository.alertLastLoopTime.value = lastLoopTime
                if let failure = lastLoopRecord["failureReason"] {
                    LoopStatusLabel.text = "X"
                    latestLoopStatusString = "X"
                } else {
                    var wasEnacted = false
                    if let enacted = lastLoopRecord["enacted"] as? [String:AnyObject] {
                        wasEnacted = true
                        if let lastTempBasal = enacted["rate"] as? Double {
                            // tableData[2].value = String(format:"%.1f", lastTempBasal)
                        }
                    }
                    if let iobdata = lastLoopRecord["iob"] as? [String:AnyObject] {
                        tableData[0].value = String(format:"%.2f", (iobdata["iob"] as! Double))
                        latestIOB = String(format:"%.2f", (iobdata["iob"] as! Double))
                    }
                    if let cobdata = lastLoopRecord["cob"] as? [String:AnyObject] {
                        tableData[1].value = String(format:"%.0f", cobdata["cob"] as! Double)
                        latestCOB = String(format:"%.0f", cobdata["cob"] as! Double)
                    }
                    if let predictdata = lastLoopRecord["predicted"] as? [String:AnyObject] {
                        let prediction = predictdata["values"] as! [Double]
                        PredictionLabel.text = bgUnits.toDisplayUnits(String(Int(prediction.last!)))
                        PredictionLabel.textColor = UIColor.systemPurple
                        predictionData.removeAll()
                        if UserDefaultsRepository.downloadPrediction.value {
                            var i = 1
                            while i <= 12 {
                                predictionData.append(prediction[i])
                                i += 1
                            }
                        }
                    }
                    if let loopStatus = lastLoopRecord["recommendedTempBasal"] as? [String:AnyObject] {
                        if let tempBasalTime = formatter.date(from: (loopStatus["timestamp"] as! String))?.timeIntervalSince1970 {
                            var lastBGTime = lastLoopTime
                            if bgData.count > 0 {
                                lastBGTime = bgData[bgData.count - 1].date
                            }
                            if tempBasalTime > lastBGTime && !wasEnacted {
                                LoopStatusLabel.text = "⏀"
                                latestLoopStatusString = "⏀"
                            } else {
                                LoopStatusLabel.text = "↻"
                                latestLoopStatusString = "↻"
                            }
                        }
                    } else {
                        LoopStatusLabel.text = "↻"
                        latestLoopStatusString = "↻"
                    }
                    
                }
                
                if ((TimeInterval(Date().timeIntervalSince1970) - lastLoopTime) / 60) > 15 {
                    LoopStatusLabel.text = "⚠"
                    latestLoopStatusString = "⚠"
                }
            } // end lastLoopTime
        } // end lastLoop Record
        
        var oText = "" as String
        currentOverride = 1.0
        if let lastOverride = lastDeviceStatus?["override"] as! [String : AnyObject]? {
            if let lastOverrideTime = formatter.date(from: (lastOverride["timestamp"] as! String))?.timeIntervalSince1970  {
            }
            if lastOverride["active"] as! Bool {
                
                let lastCorrection  = lastOverride["currentCorrectionRange"] as! [String: AnyObject]
                if let multiplier = lastOverride["multiplier"] as? Double {
                    currentOverride = multiplier
                    oText += String(format:"%.1f", multiplier*100)
                }
                else
                {
                    oText += String(format:"%.1f", 100)
                }
                oText += "% ("
                let minValue = lastCorrection["minValue"] as! Double
                let maxValue = lastCorrection["maxValue"] as! Double
                oText += bgUnits.toDisplayUnits(String(minValue)) + "-" + bgUnits.toDisplayUnits(String(maxValue)) + ")"
                
                tableData[3].value =  oText
            }
        }
        
        infoTable.reloadData()
    }
    
    // NS Cage Web Call
    func webLoadNSCage() {
        print("enter download cage")
        let urlUser = UserDefaultsRepository.url.value
        var urlString = urlUser + "/api/v1/treatments.json?find[eventType]=Site%20Change&count=1"
        if token != "" {
            urlString = urlUser + "/api/v1/treatments.json?token=" + token + "&find[eventType]=Site%20Change&count=1"
        }
        
        guard let urlData = URL(string: urlString) else {
            return
        }
        var request = URLRequest(url: urlData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if self.consoleLogging == true {print("start cage url")}
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            let decoder = JSONDecoder()
            let entriesResponse = try? decoder.decode([cageData].self, from: data)
            if let entriesResponse = entriesResponse {
                DispatchQueue.main.async {
                    self.updateCage(data: entriesResponse)
                }
            } else {
                return
            }
        }
        task.resume()
    }
    
    // NS Cage Response Processor
    func updateCage(data: [cageData]) {
        print("enter process cage")
        if consoleLogging == true {print("in updateCage")}
        if data.count == 0 {
            return
        }
        
        let lastCageString = data[0].created_at
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        UserDefaultsRepository.alertCageInsertTime.value = formatter.date(from: (lastCageString))?.timeIntervalSince1970 as! TimeInterval
        if let cageTime = formatter.date(from: (lastCageString))?.timeIntervalSince1970 {
            let now = NSDate().timeIntervalSince1970
            let secondsAgo = now - cageTime
            //let days = 24 * 60 * 60
            
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .positional // Use the appropriate positioning for the current locale
            formatter.allowedUnits = [ .day, .hour ] // Units to display in the formatted string
            formatter.zeroFormattingBehavior = [ .pad ] // Pad with zeroes where appropriate for the locale
            
            let formattedDuration = formatter.string(from: secondsAgo)
            tableData[7].value = formattedDuration ?? ""
        }
        infoTable.reloadData()
    }
    
    // NS Sage Web Call
    func webLoadNSSage() {
        print("enter download sage")
        var dayComponent    = DateComponents()
        dayComponent.day    = -10 // For removing 10 days
        let theCalendar     = Calendar.current
        
        let startDate    = theCalendar.date(byAdding: dayComponent, to: Date())!
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        var startDateString = dateFormatter.string(from: startDate)
        
        let urlUser = UserDefaultsRepository.url.value
        var urlString = urlUser + "/api/v1/treatments.json?find[eventType]=Sensor%20Start&find[created_at][$gte]=2020-05-31&count=1"
        if token != "" {
            urlString = urlUser + "/api/v1/treatments.json?token=" + token + "&find[eventType]=Sensor%20Start&find[created_at][$gte]=2020-05-31&count=1"
        }
        
        guard let urlData = URL(string: urlString) else {
            return
        }
        var request = URLRequest(url: urlData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if self.consoleLogging == true {print("start cage url")}
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            let decoder = JSONDecoder()
            let entriesResponse = try? decoder.decode([cageData].self, from: data)
            if let entriesResponse = entriesResponse {
                DispatchQueue.main.async {
                    self.updateSage(data: entriesResponse)
                }
            } else {
                return
            }
        }
        task.resume()
    }
    
    // NS Sage Response Processor
    func updateSage(data: [cageData]) {
        print("enter update sage")
        if consoleLogging == true {print("in updateSage")}
        if data.count == 0 {
            return
        }
        
        var lastSageString = data[0].created_at
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        UserDefaultsRepository.alertSageInsertTime.value = formatter.date(from: (lastSageString))?.timeIntervalSince1970 as! TimeInterval
        if let sageTime = formatter.date(from: (lastSageString as! String))?.timeIntervalSince1970 {
            let now = NSDate().timeIntervalSince1970
            let secondsAgo = now - sageTime
            let days = 24 * 60 * 60
            
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .positional // Use the appropriate positioning for the current locale
            formatter.allowedUnits = [ .day, .hour] // Units to display in the formatted string
            formatter.zeroFormattingBehavior = [ .pad ] // Pad with zeroes where appropriate for the locale
            
            let formattedDuration = formatter.string(from: secondsAgo)
            tableData[6].value = formattedDuration ?? ""
        }
        infoTable.reloadData()
    }
    
    // NS Profile Web Call
    func webLoadNSProfile() {
        print("enter download profile")
        let urlUser = UserDefaultsRepository.url.value
        var urlString = urlUser + "/api/v1/profile/current.json"
        if token != "" {
            urlString = urlUser + "/api/v1/profile/current.json?token=" + token
        }
        
        let escapedAddress = urlString.addingPercentEncoding(withAllowedCharacters:NSCharacterSet.urlQueryAllowed)
        guard let url = URL(string: escapedAddress!) else {
            return
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            
            let json = try? JSONSerialization.jsonObject(with: data) as! Dictionary<String, Any>
            
            if let json = json {
                DispatchQueue.main.async {
                    self.updateProfile(jsonDeviceStatus: json)
                }
            } else {
                return
            }
        }
        task.resume()
    }
    
    // NS Profile Response Processor
    func updateProfile(jsonDeviceStatus: Dictionary<String, Any>) {
        print("enter process profile")
        if jsonDeviceStatus.count == 0 {
            return
        }
        let basal = jsonDeviceStatus[keyPath: "store.Default.basal"] as! NSArray
        for i in 0..<basal.count {
            let dict = basal[i] as! Dictionary<String, Any>
            do {
                let thisValue = try dict[keyPath: "value"] as! Double
                let thisTime = dict[keyPath: "time"] as! String
                let thisTimeAsSeconds = dict[keyPath: "timeAsSeconds"] as! Double
                let entry = basalProfileStruct(value: thisValue, time: thisTime, timeAsSeconds: thisTimeAsSeconds)
                basalProfile.append(entry)
            } catch {
                print("Error Catch: Profile wrapped in Quotes")
            }
            
        }
    }
    
    // NS Temp Basal Web Call
    func WebLoadNSTempBasals() {
        print("enter download basals")
        if !UserDefaultsRepository.downloadBasal.value { return }
        
        let yesterdayString = dateTimeUtils.nowMinus24HoursTimeInterval()
        
        var urlString = UserDefaultsRepository.url.value + "/api/v1/treatments.json?find[eventType][$eq]=Temp%20Basal&find[created_at][$gte]=" + yesterdayString
        if token != "" {
            urlString = UserDefaultsRepository.url.value + "/api/v1/treatments.json?token=" + token + "&find[eventType][$eq]=Temp%20Basal&find[created_at][$gte]=" + yesterdayString
        }
        
        guard let urlData = URL(string: urlString) else {
            return
        }
        
        
        var request = URLRequest(url: urlData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            let json = try? (JSONSerialization.jsonObject(with: data) as! [[String:AnyObject]])
            if let json = json {
                DispatchQueue.main.async {
                    self.updateBasals(entries: json)
                }
            } else {
                return
            }
        }
        task.resume()
    }
    
    // NS Temp Basal Response Processor
    func updateBasals(entries: [[String:AnyObject]]) {
        print("enter process basal")
        // due to temp basal durations, we're going to destroy the array and load everything each cycle for the time being.
        basalData.removeAll()
        
        var lastEndDot = 0.0
        
        var tempArray: [basalGraphStruct] = []
        for i in 0..<entries.count {
            let currentEntry = entries[entries.count - 1 - i] as [String : AnyObject]?
            let basalDate = currentEntry?["timestamp"] as! String
            let strippedZone = String(basalDate.dropLast())
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
            let dateString = dateFormatter.date(from: strippedZone)
            let dateTimeStamp = dateString!.timeIntervalSince1970
            let basalRate = currentEntry?["absolute"] as! Double
            let midnightTime = dateTimeUtils.getTimeIntervalMidnightToday()
            // Setting end dots
            var duration = 0.0
            // For all except the last we're going to use stored duration for end dot. For last we'll just put it 5 mintues after the entry
            if i <= entries.count - 1 {
                duration = currentEntry?["duration"] as! Double
            } else {
                duration = dateTimeStamp + 60
            }
            
            // This adds scheduled basal wherever there is a break between temps. can't check the prior ending on the first item. it is 24 hours old, so it isn't important for display anyway
            if i > 0 {
                let priorEntry = entries[entries.count - i] as [String : AnyObject]?
                let priorBasalDate = priorEntry?["timestamp"] as! String
                let priorStrippedZone = String(priorBasalDate.dropLast())
                let priorDateFormatter = DateFormatter()
                priorDateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                priorDateFormatter.timeZone = TimeZone(abbreviation: "UTC")
                let priorDateString = dateFormatter.date(from: priorStrippedZone)
                let priorDateTimeStamp = priorDateString!.timeIntervalSince1970
                let priorDuration = priorEntry?["duration"] as! Double
                // if difference between time stamps is greater than the duration of the last entry, there is a gap
                if Double( dateTimeStamp - priorDateTimeStamp ) > Double( priorDuration * 60 ) {
                    
                    var scheduled = 0.0
                    // cycle through basal profiles.
                    // TODO figure out how to deal with profile changes that happen mid-gap
                    for b in 0..<self.basalProfile.count {
                        let scheduleTimeYesterday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightYesterday()
                        let scheduleTimeToday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightToday()
                        // check the prior temp ending to the profile seconds from midnight
                        if (priorDateTimeStamp + (priorDuration * 60)) >= scheduleTimeYesterday {
                            scheduled = basalProfile[b].value
                        }
                        if (priorDateTimeStamp + (priorDuration * 60)) >= scheduleTimeToday {
                            scheduled = basalProfile[b].value
                        }
                        
                        // This will iterate through from midnight on and set it for the highest matching one.
                    }
                    latestBasal = String(format:"%.2f", scheduled)
                    // Make the starting dot at the last ending dot
                    let startDot = basalGraphStruct(basalRate: scheduled, date: Double(priorDateTimeStamp + (priorDuration * 60)))
                    basalData.append(startDot)
                    
                    // Make the ending dot at the new starting dot
                    let endDot = basalGraphStruct(basalRate: scheduled, date: Double(dateTimeStamp))
                    basalData.append(endDot)
                    
                    
                }
            }
            
            // Make the starting dot
            let startDot = basalGraphStruct(basalRate: basalRate, date: Double(dateTimeStamp))
            basalData.append(startDot)
            
            // Make the ending dot
            // If it's the last one and not ended yet, extend it for 1 hour to match the prediction length. Otherwise let it end
            if i == entries.count - 1 && dateTimeStamp + duration <= dateTimeUtils.getNowTimeIntervalUTC() {
                lastEndDot = Date().timeIntervalSince1970 + (55 * 60)
                tableData[2].value = String(format:"%.2f", basalRate)
                latestBasal = String(format:"%.2f", basalRate)
            } else {
                lastEndDot = dateTimeStamp + (duration * 60)
            }
            
            // Double check for overlaps of incorrectly ended TBRs and sent it to end when the next one starts if it finds a discrepancy
            if i < entries.count - 1 {
                let nextEntry = entries[entries.count - 2 - i] as [String : AnyObject]?
                let nextBasalDate = nextEntry?["timestamp"] as! String
                let nextStrippedZone = String(nextBasalDate.dropLast())
                let nextDateFormatter = DateFormatter()
                nextDateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                nextDateFormatter.timeZone = TimeZone(abbreviation: "UTC")
                let nextDateString = dateFormatter.date(from: nextStrippedZone)
                let nextDateTimeStamp = nextDateString!.timeIntervalSince1970
                if nextDateTimeStamp < (dateTimeStamp + (duration * 60)) {
                    lastEndDot = nextDateTimeStamp
                }
            }
            
            let endDot = basalGraphStruct(basalRate: basalRate, date: Double(lastEndDot))
            basalData.append(endDot)
            
            
        }
        
        // If last  basal was prior to right now, we need to create one last scheduled entry
        if lastEndDot <= dateTimeUtils.getNowTimeIntervalUTC() {
            var scheduled = 0.0
            // cycle through basal profiles.
            // TODO figure out how to deal with profile changes that happen mid-gap
            for b in 0..<self.basalProfile.count {
                let scheduleTimeYesterday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightYesterday()
                let scheduleTimeToday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightToday()
                // check the prior temp ending to the profile seconds from midnight
                if lastEndDot >= scheduleTimeYesterday {
                    scheduled = basalProfile[b].value
                }
                if lastEndDot >= scheduleTimeToday {
                    scheduled = basalProfile[b].value
                }
                
                
            }
            
            tableData[2].value = String(format:"%.2f", scheduled)
            latestBasal = String(format:"%.2f", scheduled)
            // Make the starting dot at the last ending dot
            let startDot = basalGraphStruct(basalRate: scheduled, date: Double(lastEndDot))
            basalData.append(startDot)
            
            // Make the ending dot 1 hour after now
            let endDot = basalGraphStruct(basalRate: scheduled, date: Double(Date().timeIntervalSince1970))
            basalData.append(endDot)
            
            
        }
        if UserDefaultsRepository.graphBasal.value {
            updateBasalGraph()
        }
    }
    
    // NS Bolus Web Call
    func webLoadNSBoluses(){
        print("enter download bolus")
        if !UserDefaultsRepository.downloadBolus.value { return }
        let yesterdayString = dateTimeUtils.nowMinus24HoursTimeInterval()
        let urlUser = UserDefaultsRepository.url.value
        var searchString = "find[eventType]=Correction%20Bolus&find[created_at][$gte]=" + yesterdayString
        var urlDataPath: String = urlUser + "/api/v1/treatments.json?"
        if token == "" {
            urlDataPath = urlDataPath + searchString
        }
        else
        {
            urlDataPath = urlDataPath + "token=" + token + "&" + searchString
        }
        guard let urlData = URL(string: urlDataPath) else {
            return
        }
        var request = URLRequest(url: urlData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            let json = try? (JSONSerialization.jsonObject(with: data) as! [[String:AnyObject]])
            if let json = json {
                DispatchQueue.main.async {
                    self.processNSBolus(entries: json)
                }
            } else {
                return
            }
        }
        task.resume()
    }
    
    // NS Meal Bolus Response Processor
    func processNSBolus(entries: [[String:AnyObject]]) {
        print("enter process bolus")
        // because it's a small array, we're going to destroy and reload every time.
        bolusData.removeAll()
        var lastFoundIndex = 0
        for i in 0..<entries.count {
            let currentEntry = entries[entries.count - 1 - i] as [String : AnyObject]?
            let bolusDate = currentEntry?["timestamp"] as! String
            let strippedZone = String(bolusDate.dropLast())
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
            let dateString = dateFormatter.date(from: strippedZone)
            let dateTimeStamp = dateString!.timeIntervalSince1970
            do {
                let bolus = try currentEntry?["insulin"] as! Double
                let sgv = findNearestBGbyTime(needle: dateTimeStamp, haystack: bgData, startingIndex: lastFoundIndex)
                lastFoundIndex = sgv.foundIndex
                
                if dateTimeStamp < (dateTimeUtils.getNowTimeIntervalUTC() + (60 * 60)) {
                    // Make the dot
                    let dot = bolusCarbGraphStruct(value: bolus, date: Double(dateTimeStamp), sgv: Int(sgv.sgv))
                    bolusData.append(dot)
                }
            } catch {
                print("Null Bolus Warning")
            }
            
           
            
        }
        
        if UserDefaultsRepository.graphBolus.value {
            updateBolusGraph()
        }
        
    }
    
    
    // NS Carb Web Call
    func webLoadNSCarbs(){
        print("enter download carbs")
        if !UserDefaultsRepository.downloadCarbs.value { return }
        let yesterdayString = dateTimeUtils.nowMinus24HoursTimeInterval()
        let urlUser = UserDefaultsRepository.url.value
        var searchString = "find[eventType]=Meal%20Bolus&find[created_at][$gte]=" + yesterdayString
        var urlDataPath: String = urlUser + "/api/v1/treatments.json?"
        if token == "" {
            urlDataPath = urlDataPath + searchString
        }
        else
        {
            urlDataPath = urlDataPath + "token=" + token + "&" + searchString
        }
        guard let urlData = URL(string: urlDataPath) else {
            return
        }
        var request = URLRequest(url: urlData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
            
            let json = try? (JSONSerialization.jsonObject(with: data) as! [[String:AnyObject]])
            if let json = json {
                DispatchQueue.main.async {
                    self.processNSCarbs(entries: json)
                }
            } else {
                return
            }
        }
        task.resume()
    }
    
    // NS Carb Bolus Response Processor
    func processNSCarbs(entries: [[String:AnyObject]]) {
        print("enter process carbs")
        // because it's a small array, we're going to destroy and reload every time.
        carbData.removeAll()
        var lastFoundIndex = 0
        for i in 0..<entries.count {
            let currentEntry = entries[entries.count - 1 - i] as [String : AnyObject]?
            let bolusDate = currentEntry?["timestamp"] as! String
            let strippedZone = String(bolusDate.dropLast())
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
            let dateString = dateFormatter.date(from: strippedZone)
            let dateTimeStamp = dateString!.timeIntervalSince1970
            
            do {
                let carbs = try currentEntry?["carbs"] as! Double
                let sgv = findNearestBGbyTime(needle: dateTimeStamp, haystack: bgData, startingIndex: lastFoundIndex)
                lastFoundIndex = sgv.foundIndex
                
                if dateTimeStamp < (dateTimeUtils.getNowTimeIntervalUTC() + (60 * 60)) {
                    // Make the dot
                    let dot = bolusCarbGraphStruct(value: carbs, date: Double(dateTimeStamp), sgv: Int(sgv.sgv))
                    carbData.append(dot)
                }
            } catch {
                print("Null Carb Warning")
            }
            
            
        }
        
        if UserDefaultsRepository.graphCarbs.value {
            updateCarbGraph()
        }
        
        
    }
}
