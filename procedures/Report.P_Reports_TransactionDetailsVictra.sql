--liquibase formatted sql

--changeset KarinaMasihHudson:e81736ed2b5047bab51add75725c093a stripComments:false runOnChange:true splitStatements:false
/*===========================================================================================
           Rework  : Dana Jones
           Date    : May 22, 2023
   Original Author : Melissa Rios
Originally Created : 2020-09-21
       Description : Used in SSRS to email at the end of each day that day's transactions.
                   : Created new stored procedure for card: MAINT-36 Create Customized Reporting for Victra
	    BS20231102 : Added MA Account name and Id
	   KMH20231219 : If linked user created a transaction, map it to main user ID from linking table
	   KMH20231222 : Added Payment Status column
	   NG20240124  : Added Address details
	   KMH20240221 : Updated Trac Autopay Enrollment Bonus/Trac Autopay Residual orders to display ESN and SIM
                   : Added MA Name/Account ID for all orders, not just commissioned
Original Procedure : [Report].[P_Reports_TransactionDetails] by MRios
            NOTICE : Currently set to have no parameters.
             Usage : EXEC [Report].[P_Reports_TransactionDetailsVictra]
===========================================================================================*/
ALTER PROCEDURE [Report].[P_Reports_TransactionDetailsVictra]
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE @Account_ID INT = 155536; -- Victra
        --------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #ListOfAccounts;

        CREATE TABLE #ListOfAccounts (AccountID INT);

        IF
            (SELECT a.AccountType_ID FROM dbo.Account AS a WHERE a.Account_ID = @Account_ID) IN (5, 6, 8)
            BEGIN

                INSERT INTO #ListOfAccounts (AccountID)
                EXEC [Account].[P_Account_GetAccountList]
                    @AccountID = @Account_ID               -- int
                    , @UserID = 1                          -- int
                    , @AccountTypeID = '2,11'              -- varchar(50)
                    , @AccountStatusID = '0,1,2,3,4,5,6,7' -- varchar(50)
                    , @Simplified = 1;                     -- bit

            END;

        INSERT INTO #ListOfAccounts (AccountID)
        SELECT @Account_ID
        WHERE
            @Account_ID NOT IN (SELECT AccountID FROM #ListOfAccounts);

        --END;

        --------------------------------------------------------------------------------------------------------------
        DECLARE @dback SMALLINT = CASE WHEN DATENAME(WEEKDAY, GETDATE()) = 'Monday' THEN -3 ELSE -1 END;
        --SET @dback = -31;
        --------------------------------------------------------------------------------------------------------------
        -- Get orders based on Account and date (one day back)
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OrderNo;

        SELECT
            Oi.ID
            , Oi.Order_No
            , CONVERT(INT, n.AuthNumber) AS AuthNumber
        INTO #OrderNo
        FROM dbo.Order_No AS n WITH (INDEX (Ix_OrderNo_DateFilled))
        JOIN dbo.Orders AS Oi
            ON n.Order_No = Oi.Order_No
        JOIN #ListOfAccounts AS l
            ON l.AccountID = n.Account_ID
        WHERE
            n.DateFilled >= DATEADD(DAY, @dback, CONVERT(DATE, GETDATE()))
            AND n.DateFilled < CONVERT(DATETIME, CONVERT(DATE, GETDATE()));
        --
        --------------------------------------------------------------------------------------------------------------
        -- Find order based on AuthNumber
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OrderAuth;

        SELECT
            d2.ID
            , d2.Order_No
            , d2.ParentItemID
            --, ord.ID OrderId
            , d2.ID AS OrderId
        INTO #OrderAuth
        FROM #OrderNo AS ord
        JOIN dbo.Orders AS d2
            ON d2.Order_No = ord.AuthNumber
        WHERE
            ISNULL(d2.ParentItemID, 0) IN (0, 1);
        --
        --------------------------------------------------------------------------------------------------------------
        -- Get data tblOrderItemAddons based on orders
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OiA;

        SELECT A.*
        INTO #OiA
        FROM #OrderNo AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.Id = A.OrderID;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Get data tblOrderItemAddons based on AuthNumber
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OIA2;

        SELECT
            A.*
            , B.Order_No
        INTO #OIA2
        FROM #OrderAuth AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.ID = A.OrderID;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Main data gather
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #Data;

        SELECT DISTINCT
            n.Account_ID
            , c.Address1 --NG20240119
            , c.Address2 --NG20240119
            , c.City --NG20240119
            , c.State --NG20240119
            , c.Zip --NG20240119
            , n.Order_No AS [OrderNo]
            , d.ID AS OrderID
            , d.ParentItemID
            , obm.OrderBatchId AS [Batch#]
            , n.Status AS MerchantInvoiceNum
            , n1.DateDue AS MerchantDateDue
            , CONVERT(DATE, n.DateOrdered) AS DateOrdered
            , CONVERT(DATE, n.DateFilled) AS DateFilled
            , IIF(d.Name = 'Subsidy', CONCAT(d.Name, ' - ', pro.Name), d.Name) AS Product
            , CASE
                WHEN (n.OrderType_ID IN (1, 9, 19) AND n.OrderTotal > 0) THEN 'Top-Up'
                WHEN n.OrderType_ID IN (61, 62) THEN 'Marketplace Return'
                WHEN (n.OrderType_ID IN (22, 23) AND ISNULL(d.ParentItemID, 0) <> 0) THEN 'Instant Spiff'
                WHEN n.OrderType_ID IN (22, 23) THEN 'Activation'
                WHEN n.OrderType_ID IN (48, 49, 57, 58) THEN 'Marketplace Purchase'
                WHEN n.OrderType_ID IN (2, 3) THEN 'Credit Memo / Debit Memo'
                WHEN
                    n.OrderType_ID IN (59, 60)
                    AND d.Name LIKE '%month 2%' THEN 'Month 2 Promo Rebate'
                WHEN
                    n.OrderType_ID IN (59, 60)
                    AND d.Name LIKE '%month 3%' THEN 'Month 3 Promo Rebate'
                WHEN n.OrderType_ID IN (59, 60) THEN 'Instant Promo Rebate'
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 2%' THEN 'Month 2 Spiff'
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 3%' THEN 'Month 3 Spiff'
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 4%' THEN 'Month 4 Spiff'
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 5%' THEN 'Month 5 Spiff'
                WHEN n.OrderType_ID IN (45, 46) THEN 'Month 1 Spiff'
                WHEN
                    n.OrderType_ID IN (28, 38)
                    AND d.Product_ID = 13119 THEN 'Month 1 Spiff'
                WHEN n.OrderType_ID IN (28, 38) THEN 'Residual'
                ELSE oti.OrderType_Desc
            END AS [Description]
            , STUFF(
                RIGHT(' ' + CONVERT(VARCHAR(7), DATEADD(HOUR, +1, CONVERT(TIME, n.DateOrdered)), 0), 7), 6, 0, ' '
            ) AS [Time (EST)]
            , ISNULL(n.AuthNumber, '') AS [ReferenceOrderNo]
            , ISNULL(aulu.UserName, u.UserName) AS [User Name]		---KMH20231219
            , ISNULL(d.Price, 0.00) AS Retail
            , ISNULL(d.DiscAmount, 0.00) AS [Discount]
            , ISNULL((ISNULL(d.Price, 0.00) - ISNULL(d.DiscAmount, 0.00) + ISNULL(d.Fee, 0.00)), 0.00) AS Cost
            , CASE WHEN n.Paid = 1 THEN 'Paid' ELSE 'Not Paid' END AS [Payment Status]			--KMH20231222
        INTO #Data
        FROM #OrderNo AS ord
        JOIN dbo.Orders AS d
            ON
                ord.Order_No = d.Order_No
                AND d.ID = ord.ID
        JOIN dbo.Order_No AS n
            ON n.Order_No = d.Order_No
        JOIN dbo.Customers AS c
            ON c.Customer_ID = n.ShipTo
        --JOIN #OrderNo AS ord
        --    ON
        --        ord.Order_No = ord.Order_No
        --        AND d.ID = ord.ID
        LEFT JOIN dbo.Order_No AS n1
            ON n.Status = n1.Order_No
        JOIN dbo.OrderType_ID AS oti
            ON oti.OrderType_ID = n.OrderType_ID
        JOIN dbo.Users AS u
            ON u.User_ID = n.User_ID
        LEFT JOIN account.tblAccountUserLink AS aul
            ON
                aul.LinkedUserID = n.User_ID
                AND aul.AccountID = n.Account_ID
                AND aul.Active = 1
        LEFT JOIN dbo.Users AS aulu		--KMH20231219 Want the original UserID/name from linked that placed order
            ON aulu.User_ID = aul.UserID
        LEFT JOIN Products.tblPromotion AS pro
            ON pro.PromotionId = d.Dropship_Qty
        LEFT JOIN OrderManagment.tblOrderBatchMapping AS obm
            ON obm.OrderNo = ord.Order_No
        WHERE
            n.Filled = 1
            AND n.Void = 0
            AND n.Process = 1
            AND n.OrderType_ID NOT IN (12, 5, 6, 43, 44); --prepaid statement, invoice, Postpaid Second Refill, and Prepaid Second Refill
        --
        --------------------------------------------------------------------------------------------------------------
        -- Add in dbo.tblOrderItemAddons  data
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #Data2;

        SELECT DISTINCT
            d1.Account_ID
            , d1.Address1 --NG20240119
            , d1.Address2 --NG20240119
            , d1.City --NG20240119
            , d1.State --NG20240119
            , d1.Zip --NG20240119
            , d1.DateOrdered
            , d1.DateFilled
            , d1.Product
            , d1.Description
            , d1.OrderNo
            , d1.[Time (EST)]
            , d1.ReferenceOrderNo
            , d1.[User Name]
            , d1.Retail
            , d1.Discount
            , d1.Cost
            , d1.OrderID
            , d1.ParentItemID
            , d1.[Batch#]
            , d1.MerchantInvoiceNum
            , d1.MerchantDateDue --NG20240119
            , d1.[Payment Status]			--KMH20231222
            , ISNULL(oia.AddonsValue, '') AS Phone
            , IIF(
                oia5.AddonsValue = 'on'
                , 'Port'
                , IIF(oia6.AddonsValue = 'on', 'Port', IIF(d1.Product LIKE '%port%', 'Port', ''))
            ) AS IsPort -- renamed for #Data
            , CONVERT(VARCHAR(50), '') AS SIM                                                                   -- Place holder
            , CONVERT(VARCHAR(50), '') AS ESN                                                                   -- Place holder
        INTO #Data2
        FROM #Data AS d1
        LEFT JOIN #OrderAuth AS d2
            ON d2.OrderId = d1.OrderID
        LEFT JOIN dbo.tblOrderItemAddons AS oia5
            ON
                d2.ID = oia5.OrderID
                AND oia5.AddonsID = 26
        LEFT JOIN dbo.tblOrderItemAddons AS oia6
            ON
                d1.OrderID = oia6.OrderID
                AND oia6.AddonsID = 26
        LEFT JOIN #OiA AS oia
            ON
                oia.OrderID = d1.OrderID
                AND oia.AddonsID IN (8, 23) --PhoneNumberType & ReturnPhoneType
                AND LEN(oia.AddonsValue) > 6;
        --
        --Residual ESN/SIM KMH20240221
        DROP TABLE IF EXISTS #ResidualData;

        SELECT DISTINCT
            d.OrderID
            , d.OrderNo
            , odr.Account_ID
            , d.Product
            , oiar.AddonsValue AS [SIM]
            , CASE
                WHEN dcd.esn IS NOT NULL THEN dcd.ESN
                WHEN
                    LEN(oia.AddonsValue) BETWEEN 15 AND 16
                    AND ISNUMERIC(oia.AddonsValue) = 1
                    THEN oia.AddonsValue
                ELSE ''
            END AS [ESN]
        INTO #ResidualData
        FROM #Data2 AS d
        JOIN cellday_prod.dbo.Order_No AS odr
            ON odr.Order_No = d.OrderNo
        JOIN dbo.tblOrderItemAddons AS oiar
            ON oiar.OrderID = d.OrderID
        JOIN dbo.tblOrderItemAddons AS oias
            ON oias.AddonsValue = oiar.AddonsValue
        JOIN
            dbo.tblOrderItemAddons AS oia
                LEFT JOIN dbo.tblAddonFamily AS aof
                    ON
                        aof.AddonID = oia.AddonsID
                        AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            ON oias.OrderID = oia.OrderID
        LEFT JOIN Tracfone.tblDealerCommissionDetail AS dcd
            ON
                dcd.SIM = oiar.AddonsValue
                AND dcd.COMMISSION_TYPE IN ('AUTOPAY ENROLLMENT', 'AUTOPAY RESIDUAL')
        LEFT JOIN
            dbo.Orders AS o
                JOIN dbo.Order_No AS od
                    ON
                        od.Order_No = o.Order_No
                        AND od.OrderType_ID IN (22, 23)
            ON
                oia.OrderID = o.ID
                AND ISNULL(o.ParentItemID, 0) = 0
        WHERE odr.OrderType_ID IN (28, 38);

        --------------------------------------------------------------------------------------------------------------
        -- ESN
        --------------------------------------------------------------------------------------------------------------
        UPDATE d
        SET ESN = ISNULL(oia2.AddonsValue, ISNULL(oia4.AddonsValue, ISNULL(tf.TXN_PIN, ISNULL(rd.esn, ''))))
        FROM #Data2 AS d
        LEFT JOIN #OrderAuth AS d2
            ON d2.OrderId = d.OrderID
        LEFT JOIN Tracfone.tblTSPTransactionFeed AS tf
            ON tf.Order_No = d.OrderNo
        LEFT JOIN
            #OiA AS oia4
                JOIN dbo.tblAddonFamily AS f3
                    ON
                        f3.AddonID = oia4.AddonsID
                        AND f3.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            ON oia4.OrderID = d.OrderID
        LEFT JOIN
            #OIA2 AS oia2
                JOIN dbo.tblAddonFamily AS f
                    ON
                        f.AddonID = oia2.AddonsID
                        AND f.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            ON oia2.OrderID = d2.OrderId
        LEFT JOIN #ResidualData AS rd
            ON rd.OrderID = d.OrderID
        WHERE ISNULL(d.ESN, '') LIKE '';
        --
        --------------------------------------------------------------------------------------------------------------
        -- SIM
        --------------------------------------------------------------------------------------------------------------
        UPDATE d
        SET d.SIM = ISNULL(oia3.AddonsValue, ISNULL(rd.SIM, ''))
        FROM #Data2 AS d
        LEFT JOIN #OrderAuth AS d2
            ON d2.OrderId = d.OrderID
        LEFT JOIN
            #OIA2 AS oia3
                JOIN dbo.tblAddonFamily AS f2
                    ON
                        f2.AddonID = oia3.AddonsID
                        AND f2.AddonTypeName IN ('SimType', 'SimBYOPType')
            ON oia3.OrderID = d2.OrderId
        LEFT JOIN #ResidualData AS rd
            ON rd.OrderID = d.OrderID;
        ------------------------------------------------------------------------------------------------------------------------------------
        -- Commission
        ------------------------------------------------------------------------------------------------------------------------------------
        -- Logic modified from [Report].[P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions]
        -- logic added to provide commission amounts
        DROP TABLE IF EXISTS #ListOfCommInfo;

        SELECT DISTINCT
            oc.Account_ID
            , a.Account_Name AS Master_AccountName         --BS20231102
            , n.Order_No AS [MAInvoiceNumber]
            , oc.Orders_ID
            , oc.Commission_Amt
            , oc.Datedue
        INTO #ListOfCommInfo
        FROM #Data AS d
        JOIN dbo.Order_Commission AS oc
            ON
                oc.Orders_ID = d.OrderID
                AND oc.Account_ID <> 2
        JOIN dbo.Account AS a                                 --BS20231102
            ON a.Account_ID = oc.Account_ID
        LEFT JOIN dbo.Order_No AS n
            ON
                CONVERT(VARCHAR(20), oc.InvoiceNum) = n.InvoiceNum
                AND n.Account_ID = oc.Account_ID
                AND n.OrderType_ID IN (5, 6);
        --
        --------------------------------------------------------------------------------------------------------------
        -- Get final data and add totals
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #Results;

        SELECT
            CONVERT(VARCHAR(20), d.Account_ID) AS Account_ID
            , a.Account_Name
            , d.Address1 --NG20240119
            , d.Address2 --NG20240119
            , d.City --NG20240119
            , d.State --NG20240119
            , d.Zip --NG20240119
            , CONVERT(VARCHAR(20), d.DateOrdered) AS DateOrdered
            , CONVERT(VARCHAR(20), d.DateFilled) AS DateFilled
            , d.Product
            , d.Description
            , d.IsPort
            , d.[Time (EST)]
            , CONVERT(VARCHAR(25), d.OrderNo) AS OrderNo
            , d.ReferenceOrderNo
            , d.[User Name]
            , CONVERT(VARCHAR(25), d.[Batch#]) AS BatchNo
            , d.SIM
            , d.ESN
            , d.Phone
            , d.Retail
            , d.Discount
            , d.Cost
            -- These are added as per request
            , ISNULL(CONVERT(VARCHAR(20), lci.MAInvoiceNumber), '') AS MAInvoiceNumber
            , ISNULL(CONVERT(VARCHAR(20), lci.Commission_Amt), '') AS Commission_Amt
            , ISNULL(CONVERT(VARCHAR(20), lci.Datedue), '') AS [MA DateDue] --NG20240119
            , CONVERT(VARCHAR(20), ISNULL(lci.Account_ID, ISNULL(ma.Account_ID, ''))) AS Master_AccountID	--BS20231102
            , ISNULL(lci.Master_AccountName, ISNULL(ma.Account_Name, '')) AS Master_AccountName										--BS20231102
            , ISNULL(CONVERT(VARCHAR(20), d.MerchantInvoiceNum), '') AS MerchantInvoiceNumber
            , CONVERT(VARCHAR(20), d.MerchantDateDue) AS [Merchant DateDue] --NG20240119
            , d.[Payment Status]			--KMH20231222
        INTO #Results
        FROM #Data2 AS d
        JOIN dbo.Account AS a
            ON a.Account_ID = d.Account_ID
        JOIN dbo.Account AS ma
            ON ma.Account_ID = a.ParentAccount_Account_ID
        LEFT JOIN #ListOfCommInfo AS lci
            ON lci.Orders_ID = d.OrderID
        UNION
        SELECT
            '' AS Account_ID
            , '' AS Account_Name
            , '' AS Address1 --NG20240119
            , '' AS Address2 --NG20240119
            , '' AS City --NG20240119
            , '' AS State --NG20240119
            , '' AS Zip --NG20240119
            , '' AS DateOrdered
            , '' AS DateFilled
            , '' AS Product
            , 'Total Debits' AS Description
            , '' AS IsPort
            , '' AS [Time (EST)]
            , '' AS OrderNo
            , '' AS ReferenceOrderNo
            , '' AS [User Name]
            , '' AS [Batch#]
            , '' AS SIM
            , '' AS ESN
            , '' AS Phone
            , 0 AS Retail
            , 0 AS Discount
            , SUM(d2.Cost) AS [Cost]
            , '' AS MaInvoiceNumber
            , '' AS Commission_Amt
            , '' AS [MA DateDue] --NG20240119
            , '' AS Master_AccountID
            , '' AS Master_AccountName								--BS20231102
            , '' AS [Payment Status]			--KMH20231222
            , '' AS InvoiceNum
            , '' AS [Merchant DateDue] --NG20240119
        FROM #Data2 AS d2
        WHERE d2.Cost > 0
        UNION
        SELECT
            '' AS Account_ID
            , '' AS Account_Name
            , '' AS Address1 --NG20240119
            , '' AS Address2 --NG20240119
            , '' AS City --NG20240119
            , '' AS State --NG20240119
            , '' AS Zip --NG20240119
            , '' AS DateOrdered
            , '' AS DateFilled
            , '' AS Product
            , 'Total Credits' AS Description
            , '' AS IsPort
            , '' AS [Time (EST)]
            , '' AS OrderNo
            , '' AS ReferenceOrderNo
            , '' AS [User Name]
            , '' AS [Batch#]
            , '' AS SIM
            , '' AS ESN
            , '' AS Phone
            , 0 AS Retail
            , 0 AS Discount
            , SUM(d2.Cost) AS [Cost]
            , '' AS MaInvoiceNumber
            , '' AS Commission_Amt
            , '' AS [MA DateDue] --NG20240119
            , '' AS Master_AccountID
            , '' AS Master_AccountName							--BS20231102
            , '' AS [Payment Status]			--KMH20231222
            , '' AS InvoiceNum
            , '' AS [Merchant DateDue] --NG20240119
        FROM #Data2 AS d2
        WHERE d2.Cost < 0;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Report
        --------------------------------------------------------------------------------------------------------------
        SELECT DISTINCT
            r.Account_ID
            , r.Account_Name
            , r.Address1 --NG20240119
            , r.Address2 --NG20240119
            , r.City --NG20240119
            , r.State --NG20240119
            , r.Zip --NG20240119
            , r.DateOrdered
            , r.DateFilled
            , r.Product
            , r.Description
            , r.IsPort
            , r.[Time (EST)]
            , r.OrderNo
            , r.ReferenceOrderNo
            , r.[User Name]
            , r.BatchNo
            , r.SIM
            , r.ESN
            , r.Phone
            , r.MAInvoiceNumber       -- DJJ20230517
            , r.Commission_Amt        -- DJJ20230517
            , r.[MA DateDue]               -- DJJ20230517
            , r.MerchantInvoiceNumber -- DJJ20230517
            , r.[Merchant DateDue] --NG20240119
            , r.Retail
            , r.Discount
            , r.Cost
            , r.Master_AccountID --BS20231102
            , r.Master_AccountName --BS20231102
            , r.[Payment Status] --KMH20231222
        FROM #Results AS r
        ORDER BY r.OrderNo DESC;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Cleanup
        --------------------------------------------------------------------------------------------------------------
        --DROP TABLE IF EXISTS #Data2;
        --DROP TABLE IF EXISTS #Data;
        --DROP TABLE IF EXISTS #OiA;
        --DROP TABLE IF EXISTS #Results;
        --DROP TABLE IF EXISTS #ListOfAccounts;
        --DROP TABLE IF EXISTS #ListOfCommInfo;
        --DROP TABLE IF EXISTS #OIA2;
        --DROP TABLE IF EXISTS #OrderAuth;
        --DROP TABLE IF EXISTS #OrderNo;
    --------------------------------------------------------------------------------------------------------------
    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber
            , ERROR_MESSAGE() AS ErrorMessage;
    END CATCH
END;
