--liquibase formatted sql

--changeset  NicolasGriesdorn:37db375a stripComments:false runOnChange:true splitStatements:false

-- noqa: disable=all
/****** Object:  StoredProcedure [Report].[P_BrandedHandset_Sales_Detail]    Script Date: 8/2/2023 7:42:00 AM ******/
 /*=============================================
      Author : Li Zhou
             :
 Create Date : 2016-10-06
             :
 Description : Report shows sales detail of Branded handset data for Master Agent
             :
       Usage : EXEC Report.P_BrandedHandset_Sales_Detail 12747, NULL, NULL, '2023-05-01', '2023-05-01 09:00', 1
             :
 LZ20170522  : ESN device activated outside of vidapay will be showed without activation order.
 JL20170526  : INC-77340
 LZ20170606  : INC-78177
 LZ20171016  : Ultra BH
 JR20171019  : Excluded Total Wireless branded sales whose dates where changed for promo.
 JR20171101  : Now including [CellDayTemp].[Bck].[Inc89581_TotalWirelessBHOrderOriginalInfo]
             : if the account ID, order #, or date range intrudes into ..OriginalInfo data.
 LZ20171211  : remove TW part
 JR20180206  : JOIN'd in [OrderManagment].[tblOrderTracking] INTO #detail table to retrieve
             : Verizon tracking numbers.  #INC-95825
 LZ20180508  : Left Join Commission
 LZ20180531  : Performance optimization
 LZ20180726  : INC118034
 LZ20180730  : INC118450
 LZ20180829  : Support multi accounts
 LZ20190118  : inc133592
 KMH20200916 : Added Invoice Number and Invoice Date columns
 KMH20210329 : Added Tracfone Tier column to final select
 DJ20210602  : Move inline query for Tracfone.tblTracfoneMAIDMapping to temp table for indexing
 KMH20220228 : Added payment method to #OID and downstream tables for output view
             : Added new IF ELSE @MPID=2 so Payment Method would display for Tracfone and Verizon only
             : Added "dbo" schema to tables that were lacking it
 DJJ20220603 : Add column for rebate amount to report based on ActivationOrder = AuthNumber
 DJJ20220623 : Duplicating so added DISTINCT on #detail
 NG20230215  : Added VendorID column to TF MP ID
 BS20230303  : Added MA Ordered User ID and Name
 BS20230410  : Added Carrier Tier Stats
 JR20230508  : Added ac.ParentAccount_Account_ID AS [Parent ID]
 DJJ20230802 : Modify @MPID to take two characters.  Could not test so did not make INT
 NG20231027  : Rework of OrderTracking to bring in Order Tracking details instead of Reference Numbers
 NG20240118  : Added Shipping Address (BusinessAddress) and also added Assigned Current Account Address
 NG20240216  : Fixed spacing issue that was causing report to fail
 --Test: 218728194
---------------------------------------------------------------------------------------------------------
 MP IDs (SELECT BrandedMPID,BrandedMPName FROM MarketPlace.tblBrandedMP):
 1 - Tracfone
 2 - Verizon
 3 - Ultra
 5 - Elite
 9 - Cricket
 10 - TBV
 11 - Gen Mobile
=============================================*/
-- noqa: enable=all
CREATE OR ALTER PROC [Report].[P_BrandedHandset_Sales_Detail]
    (
        @Session_ID INT,           -- Login Account
        @ACCOUNT_ID NVARCHAR(100),  -- Merchants ID
        @OrderNo NVARCHAR(100),
        @StartDate DATETIME,
        @EndDate DATETIME,
        @MPID NCHAR(2)       -- DJJ20230802 changed from NCHAR(1)
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        SET NOCOUNT ON;

        DECLARE @JobID INT = -1;

        DECLARE @RunMA INT = CASE
            WHEN @Session_ID = @JobID
                THEN 2
            ELSE @Session_ID
        END;

        IF
            NOT EXISTS (
                SELECT 1
                FROM MarketPlace.tblBrandedMP
                WHERE BrandedMPID = ISNULL(@MPID, '0')
            )
            BEGIN
                SELECT 'Invalid Vendor.' AS [ERROR];
                RETURN;
            END;

        DECLARE @intMPID TINYINT = CAST(@MPID AS TINYINT);

        IF ISNULL(@StartDate, '') = ''
            SET @StartDate = dateadd(D, -1, CAST(getdate() AS DATE));

        IF ISNULL(@EndDate, '') = ''
            SET @EndDate = CAST(getdate() AS DATE);

        IF @StartDate >= @EndDate
            BEGIN
                SELECT 'Incorrect date range. Please check your input dates and try again.' AS [Error];
                RETURN;
            END;

        IF object_id(N'tempdb..#MA') IS NOT NULL
            DROP TABLE #MA;

        IF object_id(N'tempdb..#Merchant') IS NOT NULL
            DROP TABLE #Merchant;

        DECLARE @PHid HIERARCHYID = (SELECT Hierarchy FROM dbo.Account WHERE Account_ID = @RunMA);

        CREATE TABLE #MA
        (
            ACCOUNT_ID INT
        );
        CREATE TABLE #Merchant
        (
            Account_id INT
        );

        INSERT INTO #MA
        (
            ACCOUNT_ID
        )
        SELECT Account_ID
        FROM dbo.Account
        WHERE
            Hierarchy.IsDescendantOf(@PHid) = 1 AND ACCOUNT_ID <> @RunMA
            AND AccountType_ID IN (5, 6, 12);

        INSERT INTO #MA
        VALUES
        (@RunMA);

        IF
            len(isnull(@ACCOUNT_ID, '')) = 0
            AND len(isnull(@OrderNo, '')) = 0
            BEGIN
                INSERT INTO #Merchant
                (
                    Account_id
                )
                SELECT Account_ID
                FROM dbo.Account
                WHERE
                    Hierarchy.IsDescendantOf(@PHid) = 1
                    AND AccountType_ID IN (2, 11);

            END;

        -- provided order_no
        IF len(isnull(@OrderNo, '')) > 0
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM Order_No WHERE Order_No = @OrderNo)
                    BEGIN
                        SELECT 'Invalid Order number.' AS [Error];
                        RETURN;
                    END;

                IF
                    (
                        SELECT patindex('%' + CAST(@RunMA AS NVARCHAR(6)) + '%', Hierarchy.ToString())
                        FROM dbo.Account AS ac
                        JOIN dbo.Order_No AS o
                            ON ac.Account_ID = o.Account_ID
                        WHERE o.Order_No = CAST(@OrderNo AS INT)
                    ) = 0
                    BEGIN
                        SELECT
                            'The submitted order # does not belong to you(or any one of your sub-master agents).'
                                AS [Error]
                        UNION
                        SELECT '     You are not allowed access.' AS [Error];
                        RETURN;
                    END;
            END;

        -- provided merchant
        IF len(isnull(@ACCOUNT_ID, '')) > 0
            BEGIN
                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM Account AS a
                        JOIN (SELECT id FROM dbo.fnSplitter(@ACCOUNT_ID)) AS d ON a.Account_ID = d.ID
                    )
                    BEGIN
                        SELECT
                            'Invalid Account ID. Please check your submitted Account ID and try again.' AS [Error];
                        RETURN;
                    END;

                IF
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.Account AS a
                        JOIN (SELECT id FROM dbo.fnSplitter(@ACCOUNT_ID)) AS d ON a.Account_ID = d.ID
                        WHERE
                            a.AccountType_ID IN (2, 11)
                            AND a.Hierarchy.IsDescendantOf(@PHid) = 0
                    )
                    BEGIN
                        SELECT
                            'The given accounts does not belong to you(or any one of your sub-master agents).'
                                AS [Error]
                        UNION
                        SELECT '     You are not allowed access.' AS [Error];
                        RETURN;
                    END;
                ELSE
                    BEGIN
                        INSERT INTO #Merchant
                        (
                            Account_id
                        )
                        SELECT id FROM dbo.fnSplitter(@ACCOUNT_ID) AS i
                        WHERE
                            NOT EXISTS
                            (
                                SELECT 1 FROM #Merchant AS m WHERE m.Account_id = i.ID
                            );
                    END;
            END;

        IF object_id(N'tempdb..#TracProduct') IS NOT NULL
            DROP TABLE #TracProduct;

        --- Product filter;
        SELECT DISTINCT
            (p.ProductID) AS BHProductID
        INTO #TracProduct
        FROM MarketPlace.tblBrandedMPTiers AS t
        JOIN MarketPlace.tblBrandedMPTierProducts AS p
            ON t.BrandedMPTierID = p.BrandedMPTierID
        JOIN MarketPlace.tblAccountBrandedMPTier AS bt
            ON bt.BrandedMPID = t.BrandedMPID
        WHERE t.BrandedMPID = @intMPID;

        ----------------------------------------------------------------------------- pull data
        IF object_id(N'tempdb..#OrderInfo') IS NOT NULL
            BEGIN
                DROP TABLE #OID;
            END;

        SELECT
            od.Order_No
            , od.Account_ID
            , od.[User_ID]                                    --BS20230303
            , o.ID
            , od.DateOrdered AS DateOrdered
            , od.DateFilled AS DateFilled
            , o.Product_ID
            , o.Name
            , o.SKU
            , c.Address1 AS BusinessAddress1
            , c.Address2 AS BusinessAddress2
            , c.City AS BusinessCity
            , c.State AS BusinessState --NG20240118
            , c.Zip AS BusinessZipCode --NG20240118
            , (
                CASE
                    WHEN od.Void = 1
                        THEN
                            'Voided'
                    WHEN
                        od.Filled = 0
                        AND od.Process = 0
                        THEN
                            'Pending'
                    WHEN od.Filled = 1
                        THEN
                            'Filled'
                    ELSE
                        'Unknown'
                END
            ) AS OrderStatus --NG20240118
            , (o.Price - o.DiscAmount) AS DealerCost --NG20240118
            , COALESCE(o2.Name, 'Account Balance') AS [Payment Method] --NG20240118
        INTO #OID
        FROM dbo.Order_No AS od
        JOIN #Merchant AS m
            ON m.Account_id = od.Account_ID
        JOIN dbo.Orders AS o
            ON o.Order_No = od.Order_No
        LEFT JOIN Orders.tblOrderLinking AS ol        --KMH20220228
            ON ol.OrderNo = od.Order_No
        LEFT JOIN
            Orders.tblOrderLinking AS ol2        --KMH20220228
                JOIN dbo.order_No AS od2                    --KMH20220228
                    ON
                        od2.Order_No = ol2.OrderNo
                        AND od2.OrderType_ID IN (76, 77)
            ON
                ol2.OrderNoLinkingId = ol.OrderNoLinkingId
                AND ol2.OrderLinkingTypeId = 1
        LEFT JOIN dbo.orders AS o2                    --KMH20220228
            ON o2.Order_No = od2.Order_No
        LEFT JOIN dbo.Customers AS c --NG20240118
            ON c.Customer_ID = od.ShipTo
        WHERE
            od.OrderType_ID IN (57, 58)
            AND od.DateOrdered
            BETWEEN @StartDate AND @EndDate;

        INSERT INTO #OID
        SELECT
            od.Order_No
            , od.Account_ID
            , od.[User_ID]
            , o.ID
            , od.DateOrdered
            , od.DateFilled AS DateFilled
            , o.Product_ID
            , o.Name
            , o.SKU
            , c.Address1 AS BusinessAddress1 --NG20240118
            , c.Address2 AS BusinessAddress2 --NG20240118
            , c.City AS BusinessCity --NG20240118
            , c.State AS BusinessState --NG20240118
            , c.Zip AS BusinessZipCode --NG20240118
            , (
                CASE
                    WHEN od.Void = 1
                        THEN
                            'Voided'
                    WHEN
                        od.Filled = 0
                        AND od.Process = 0
                        THEN
                            'Pending'
                    WHEN od.Filled = 1
                        THEN
                            'Filled'
                    ELSE
                        'Unknown'
                END
            ) AS OrderStatus
            , (o.Price - o.DiscAmount) AS DealerCost
            , COALESCE(o2.Name, 'Account Balance') AS [Payment Method]
        FROM dbo.Order_No AS od
        JOIN dbo.Orders AS o
            ON o.Order_No = od.Order_No
        LEFT JOIN Orders.tblOrderLinking AS ol        --KMH20220228
            ON ol.OrderNo = od.Order_No
        LEFT JOIN
            Orders.tblOrderLinking AS ol2        --KMH20220228
                JOIN dbo.order_No AS od2                    --KMH20220228
                    ON
                        od2.Order_No = ol2.OrderNo
                        AND od2.OrderType_ID IN (76, 77)
            ON
                ol2.OrderNoLinkingId = ol.OrderNoLinkingId
                AND ol2.OrderLinkingTypeId = 1
        LEFT JOIN dbo.orders AS o2                    --KMH20220228
            ON o2.Order_No = od2.Order_No
        LEFT JOIN dbo.Customers AS c --NG20240118
            ON c.Customer_ID = od.ShipTo
        WHERE
            od.Order_No = @OrderNo
            AND len(isnull(@OrderNo, '')) > 7;

        IF object_id(N'tempdb..#top') IS NOT NULL
            DROP TABLE #top;

            ; WITH ACCNT AS (
            SELECT DISTINCT
                Account_ID
            FROM #OID
        )
        SELECT
            a.Account_ID
            , isnull(dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy), 2) AS TopMA
        INTO #top
        FROM ACCNT AS a
        JOIN dbo.Account AS ac
            ON ac.Account_ID = a.Account_ID;

        --------------------------------------------------------------BS20230410
        IF OBJECT_ID('tempdb..#AccountCarrierTier') IS NOT NULL
            BEGIN
                DROP TABLE #AccountCarrierTier
            END;

        CREATE TABLE #AccountCarrierTier
        (
            CarrierId INT,
            AccountId INT,
            ProgramCarrier VARCHAR(50),
            ProgramStatus VARCHAR(50),
            ProgramTier VARCHAR(50)
        )

        INSERT INTO #AccountCarrierTier
        SELECT
            1, -- noqa: AL03
            ttar.Account_ID,
            'Tracfone', -- noqa: AL03
            CASE
                WHEN ttar.TracfoneStatus = 1 THEN 'Certified'
                WHEN ttar.TracfoneStatus = 2 THEN 'Pending'
                WHEN ttar.TracfoneStatus = 3 THEN 'Suspend'
                WHEN ttar.TracfoneStatus = 4 THEN 'New'
                WHEN ttar.TracfoneStatus = 5 THEN 'PendingResubmitted'
                WHEN ttar.TracfoneStatus = 7 THEN 'SuspendedResubmitted'
                WHEN ttar.TracfoneStatus = 8 THEN 'SuspendedFraud'
                ELSE 'Unknown'
            END AS [Tracfone Status],
            CASE
                WHEN ttar.TracfoneTierId = 1 THEN 'Silver'
                WHEN ttar.TracfoneTierId = 2 THEN 'Gold'
                WHEN ttar.TracfoneTierId = 3 THEN 'Platinum'
                WHEN ttar.TracfoneTierId = 4 THEN 'Bronze'
                WHEN ttar.TracfoneTierId = 5 THEN 'Pro'
                WHEN ttar.TracfoneTierId = 6 THEN 'Elite'
                WHEN ttar.TracfoneTierId = 7 THEN 'VIP'
                WHEN ttar.TracfoneTierId = 8 THEN 'Vip15'
                WHEN ttar.TracfoneTierId = 9 THEN 'Vip25'
                WHEN ttar.TracfoneTierId = 10 THEN 'VipPlus15'
                WHEN ttar.TracfoneTierId = 11 THEN 'VipPlus25'
                WHEN ttar.TracfoneTierId = 12 THEN 'VipPlus100'
                ELSE 'Unknown'
            END AS [Tracfone Tier]
        FROM [Tracfone].[tblTracTSPAccountRegistration] AS ttar
        JOIN #Merchant AS m ON CAST(m.Account_id AS VARCHAR(50)) = ttar.Account_ID
        WHERE TRY_CAST(ttar.Account_ID AS INT) IS NOT NULL

        INSERT INTO #AccountCarrierTier
        SELECT c.Id, tat.Account_Id, c.Carrier_Name, vass.[Description], t.[Name]
        FROM [CarrierSetup].[tblVzwAccountStore] AS vas
        JOIN [CarrierSetup].[tblVzwAccountStoreStatus] AS vass ON vass.StatusID = vas.StatusID
        JOIN Account.tblAccountTier AS tat ON tat.Account_Id = vas.AccountId
        JOIN CarrierSetup.tblTier AS t ON tat.TierId = t.TierId
        JOIN dbo.Carrier_ID AS c ON c.ID = tat.Carrier_Id
        JOIN #Merchant AS m ON m.Account_id = vas.AccountId
        WHERE tat.Carrier_Id = 7

        --------------------------------------------------------------BS20230410

        IF object_id(N'tempdb..#OrderInfo') IS NOT NULL
            BEGIN
                DROP TABLE #OrderInfo;
            END;

        IF object_id(N'tempdb..#detail') IS NOT NULL
            DROP TABLE #detail;

        --- Order detail
        SELECT DISTINCT
            o.Order_No                      -- DJJ20220623 : Duplicating so added DISTINCT on #detail
            , o.Account_ID
            , o.[User_ID]                                -- BS20230303
            , t.TopMA
            , o.OrderStatus
            , o.ID
            , o.DateFilled
            , o.DateOrdered
            , o.Product_ID
            , o.Name
            , o.DealerCost
            , o.[Payment Method]                    -- KMH20220228
            , tpm.VendorID                            -- NG20230215
            , act.ProgramTier AS VZWTier
            , act1.ProgramTier AS TFTier
            , o.BusinessAddress1             --BS20230410
            , o.BusinessAddress2            --BS20230410
            , o.BusinessCity --NG20240118
            , o.BusinessState --NG20240118
            , o.BusinessZipCode --NG20240118
            , isnull(e.AddonsValue, '') AS ESN --NG20240118
            , isnull(s.AddonsValue, '') AS SIM --NG20240118
        INTO #OrderInfo
        FROM #OID AS o
        JOIN #top AS t
            ON t.Account_ID = o.Account_ID
        JOIN #TracProduct AS p
            ON o.Product_ID = p.BHProductID
        JOIN Products.tblProductMapping AS tpm
            ON o.Product_ID = tpm.ProductID
        JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.BHProductID
        LEFT JOIN dbo.tblOrderItemAddons AS s
            ON
                s.OrderID = o.ID
                AND s.AddonsID = 21
        LEFT JOIN dbo.tblOrderItemAddons AS e
            ON
                e.OrderID = o.ID
                AND e.AddonsID = 17
        LEFT JOIN #AccountCarrierTier AS act                        --BS20230410
            ON
                act.CarrierId = 7
                AND act.AccountId = t.Account_ID
        LEFT JOIN #AccountCarrierTier AS act1            --BS20230410
            ON
                act1.CarrierId = 1
                AND act1.AccountId = t.Account_ID

        SELECT
            n.Order_No
            , n.Account_ID
            , n.[User_ID]                              -- BS20230303
            , n.TopMA
            , ot.TrackingNumber --NG20231027
            , n.ID AS Order_ID
            , n.SIM
            , n.ESN
            , n.OrderStatus
            , n.DateOrdered
            , n.DateFilled AS DateFilled
            , n.Product_ID
            , n.Name
            , pm.VendorSku AS PartNumber
            , pm.VendorID AS VendorID
            , n.DealerCost
            --------------------------------------------------------------------------------------------
            , n.[Payment Method]  -- DJJ20220603 place holder for rebate info
            --------------------------------------------------------------------------------------------
            , n.VZWTier                            --KMH20220228
            , n.TFTier
            , e.Assigned_Merchant_ID AS CurrentAssignedAccountID
            , a.Account_Name AS CurrentAssignedAccountName
            , c.Address1 AS CurrentAssignedAccountAddress1                     --BS20230410
            , c.Address2 AS CurrentAssignedAccountAddress2                         --BS20230410
            , c.City AS CurrentAssignedAccountCity --NG20240118
            , c.State AS CurrentAssignedAccountState --NG20240118
            , c.Zip AS CurrentAssignedAccountZip --NG20240118
            , n.BusinessAddress1 --NG20240118
            , n.BusinessAddress2 --NG20240118
            , n.BusinessCity --NG20240118
            , n.BusinessState --NG20240118
            , n.BusinessZipCode --NG20240118
            , CAST(0 AS DECIMAL(9, 2)) AS PRebate --NG20240118
            , CASE
                WHEN
                    act.Order_No IS NOT NULL
                    OR e.Active_Status = 1
                    THEN
                        'Activated'
                ELSE
                    'Not Activated'
            END AS Active_Status --NG20240118
            , isnull(act.Order_No, '') AS ActivationOrder --NG20240118
            , isnull(act.DateOrdered, '') AS DateActivated --NG20240118
        INTO #detail
        FROM #OrderInfo AS n
        JOIN Products.tblProductMapping AS pm
            ON
                n.Product_ID = pm.ProductID
                AND pm.IsDefault = 1
        LEFT JOIN Tracfone.tblHandsetESN AS esn
            ON
                n.ID = esn.OrderId
                AND esn.Processed = 1
        LEFT JOIN [OrderManagment].[tblOrderTracking] AS ot --20231027
            ON n.Order_No = ot.OrderNo
        LEFT JOIN dbo.Phone_Active_Kit AS e
            ON
                n.ESN = e.Sim_ID
                AND e.Status = 1
                AND e.PONumber = n.Order_No
        LEFT JOIN dbo.Order_No AS act
            ON
                isnull(e.order_no, 0) = act.Order_No
                AND act.Void <> 1
        LEFT JOIN Account AS a --NG20240118
            ON a.Account_ID = e.Assigned_Merchant_ID
        LEFT JOIN dbo.Customers AS c --NG20240118
            ON c.Customer_ID = a.Customer_ID


        --------------------------------------------------------------------------------------------v-- DJJ20220603
        -- Populate the rebate amount with data based on Activation Order number = AuthNumber
        UPDATE dt
        SET PRebate = OrdS.Price
        FROM #detail AS dt
        JOIN dbo.Order_No AS OrdN ON dt.ActivationOrder = OrdN.AuthNumber
        JOIN dbo.Orders AS OrdS ON OrdN.Order_No = OrdS.Order_No
        WHERE OrdN.OrderType_ID IN (59, 60);  -- promo order
        --------------------------------------------------------------------------------------------^-- DJJ20220603

        CREATE CLUSTERED INDEX idx_#detail ON #detail (Account_ID); -- noqa: RF05
        CREATE NONCLUSTERED INDEX nidx_#detail ON #detail (ActivationOrder) WHERE (ActivationOrder > 0); -- noqa: RF05

        IF object_id(N'tempdb..#Acativation') IS NOT NULL
            DROP TABLE #Acativation;

        SELECT DISTINCT a.ActivationOrder
        INTO #Acativation
        FROM #detail AS a
        JOIN dbo.orders AS o ON a.ActivationOrder = o.Order_No AND o.ParentItemID = 0
        JOIN
            dbo.tblOrderItemAddons AS oia WITH (INDEX (IX_tblOrderItemAddons_OrderId))
            ON oia.OrderID = o.ID AND oia.AddonsID = 26
        WHERE isnull(a.ActivationOrder, 0) > 0

        IF object_id(N'tempdb..#commission') IS NOT NULL
            DROP TABLE #commission;

        --- Calculate commission
        SELECT
            oc.Orders_ID AS Order_ID
            , sum(
                CASE
                    WHEN dt.OrderStatus = 'Voided'
                        THEN
                            0
                    ELSE
                        isnull(oc.Commission_Amt, 0)
                END
            ) AS MACommission
        INTO #commission
        FROM dbo.Order_Commission AS oc --with (index =IX_Order_Commission_OrderId_Order_No)
        JOIN #detail AS dt
            ON dt.Order_ID = oc.Orders_ID
        JOIN #MA
            ON oc.Account_ID = #MA.ACCOUNT_ID
        GROUP BY oc.Orders_ID;

        ---------------KM20200916
        IF OBJECT_ID('tempdb..#OrderCommission') IS NOT NULL
            BEGIN
                DROP TABLE #OrderCommission
            END;

        SELECT *
        INTO #OrderCommission
        FROM (
            SELECT
                oi.Order_No
                , oi.TopMA
                , oc.Orders_ID
                , od.Order_No AS [Session ID Invoice Number]
                , od.DateDue AS [Session ID Invoice Date]
                , ROW_NUMBER() OVER (PARTITION BY oc.Orders_ID ORDER BY oc.Order_No) AS RowNumber
            FROM #OrderInfo AS oi
            JOIN dbo.Order_Commission AS oc
                ON oc.Orders_ID = oi.ID
            JOIN dbo.Order_No AS od
                ON oc.InvoiceNum = od.InvoiceNum AND od.OrderType_ID = 6 AND od.Account_ID = @Session_ID
        ) AS inv
        WHERE RowNumber = 1;
        -------------KM20200916

        -----------------------------------v-- DJ20210602
        -- Changed from inline to temp table so index could be added
        IF OBJECT_ID('tempdb..#tempMAIDMap') IS NOT NULL DROP TABLE #tempMAIDMap;
        SELECT
            TopParentID
            , TracfoneMAID
        INTO #tempMAIDMap
        FROM Tracfone.tblTracfoneMAIDMapping
        WHERE TracfoneMAID IS NOT NULL
        UNION
        SELECT
            111992 AS TopParentID
            , 2 AS TracfoneMAID;

        CREATE INDEX idx_tempMAIDMap ON #tempMAIDMap (TopParentID);
        -----------------------------------^-- DJ20210602
        IF (@Session_ID <> @JobID AND @Session_ID <> 2)
            BEGIN
                SET @MPID = 2;
            END;

        --- Merchant infomation;
        IF (@Session_ID = 2 AND @MPID = 1)
            BEGIN
                SELECT
                    ac.Account_ID AS [Merchant ID]
                    , ac.Account_Name AS [Merchant Name]
                    , ac.ParentAccount_Account_ID AS [Parent ID]
                    , mau.[User_Id] AS [MA Ordered User Id]     -- BS20230303
                    , mau.UserName AS [MA Ordered User Name]   -- BS20230303
                    , tc.TierName AS [Tracfone Tier]
                    , u.UserName AS [SalesRep Name]
                    , tpa.Account_ID AS [Top MA Account ID]
                    , tpa.Account_Name AS [Top MA Account Name]
                    , tma.TracfoneMAID AS [Top TF MA Account ID]
                    , trac.Account_Name AS [Top TF MA Account Name]
                    , dt.Order_No AS [Order Number]
                    , dt.TrackingNumber AS [Tracking Number]
                    , dt.BusinessAddress1 AS [Business Address 1] --NG20240118
                    , dt.BusinessAddress2 AS [Business Address 2] --NG20240118
                    , dt.BusinessCity AS [Business City] --NG20240118
                    , dt.BusinessState AS [Business State] --NG20240118
                    , dt.BusinessZipCode AS [Business Zip Code] --NG20240118
                    , dt.SIM AS [SIM]
                    , dt.ESN AS [ESN]
                    , dt.OrderStatus AS [Status]
                    , dt.DateOrdered AS [Date Ordered]
                    , dt.DateFilled AS [Date filled]
                    , dt.Product_ID AS [Product ID]
                    , dt.Name AS [Product Name]
                    , dt.PartNumber AS [Part Number]
                    , dt.DealerCost AS [Dealer Cost]
                    , dt.PRebate AS [Rebate]
                    -- DJJ20220603 -- Rebate based on Activation OrderNo = AuthNumber
                    , dt.[Payment Method] AS [Payment Method]
                    , dt.Active_Status AS [Activation Status]         -- KMH20220228
                    , dt.ActivationOrder AS [Activation OrderNo]
                    , dt.VendorID AS [Vendor ID]
                    , dt.DateActivated AS [Date Activated]              -- NG20230215

                    , oc.[Session ID Invoice Number]

                    , oc.[Session ID Invoice Date]

                    , dt.VZWTier
                    , dt.TFTier
                    , dt.CurrentAssignedAccountID                        --BS20230410
                    , dt.CurrentAssignedAccountName                         --BS20230410
                    , dt.CurrentAssignedAccountAddress1   --NG20240118
                    , dt.CurrentAssignedAccountAddress2 --NG20240118
                    , dt.CurrentAssignedAccountCity --NG20240118
                    , dt.CurrentAssignedAccountState --NG20240118
                    , dt.CurrentAssignedAccountZip --NG20240118
                    , isnull(cm.MACommission, 0) AS [MA Commission] --NG20240118
                    , IIF(atv.ActivationOrder IS NOT NULL, 'Yes', 'NO') AS [IsPortIN] --NG20240118
                FROM #detail AS dt
                JOIN dbo.Account AS ac
                    ON ac.Account_ID = dt.Account_ID
                JOIN dbo.Users AS u
                    ON ac.ParentAccount_SalesRep_UserID = u.User_ID
                JOIN dbo.Account AS tpa
                    ON tpa.Account_ID = dt.TopMA
                JOIN #tempMAIDMap AS tma                                                   -- DJ20210602
                    ON tpa.Account_ID = tma.TopParentID
                JOIN dbo.Account AS trac
                    ON tma.TracfoneMAID = trac.Account_ID
                LEFT JOIN [Account].[tblAccountUserLink] AS lu                                    --BS20230303
                    ON dt.User_Id = lu.LinkedUserID
                LEFT JOIN dbo.Users AS mau
                    ON mau.User_ID = lu.UserID
                LEFT JOIN tracfone.tblAirtimeMarginTier AS amt                                -- KM20210329
                    ON amt.AccountId = ac.Account_ID AND amt.Enddate >= GETDATE()
                LEFT JOIN tracfone.tblTierCode AS tc                                        -- KM20210329
                    ON tc.TierCode = amt.TierCode AND tc.TierId = amt.TierId
                LEFT JOIN #commission AS cm
                    ON cm.Order_ID = dt.Order_ID
                LEFT JOIN #Acativation AS atv ON atv.ActivationOrder = dt.ActivationOrder
                LEFT JOIN #OrderCommission AS oc
                    ON oc.Orders_ID = dt.Order_ID
                ORDER BY [Order Number];
            END;
        ELSE IF @MPID = 1
            BEGIN
                SELECT
                    ac.Account_ID AS [Merchant ID]
                    , ac.Account_Name AS [Merchant Name]
                    , ac.ParentAccount_Account_ID AS [Parent ID]
                    , mau.[User_Id] AS [MA Ordered User Id]   -- BS20230303
                    , mau.UserName AS [MA Ordered User Name] -- BS20230303
                    , tc.TierName AS [Tracfone Tier]
                    , u.UserName AS [SalesRep Name]
                    , tma.TracfoneMAID AS [Top TF MA Account ID]
                    , trac.Account_Name AS [Top TF MA Account Name]
                    , dt.Order_No AS [Order Number]
                    , dt.TrackingNumber AS [Tracking Number]
                    , dt.BusinessAddress1 AS [Business Address 1] --NG20240118
                    , dt.BusinessAddress2 AS [Business Address 2] --NG20240118
                    , dt.BusinessCity AS [Business City] --NG20240118
                    , dt.BusinessState AS [Business State] --NG20240118
                    , dt.BusinessZipCode AS [Business Zip Code] --NG20240118
                    , dt.SIM AS [SIM]
                    , dt.ESN AS [ESN]
                    , dt.OrderStatus AS [Status]
                    , dt.DateOrdered AS [Date Ordered]
                    , dt.DateFilled AS [Date filled]
                    , dt.Product_ID AS [Product ID]
                    , dt.Name AS [Product Name]
                    , dt.PartNumber AS [Part Number]
                    , dt.DealerCost AS [Dealer Cost]
                    , dt.PRebate AS [Rebate]
                    -- DJJ20220603 -- Rebate based on Activation OrderNo = AuthNumber
                    , dt.[Payment Method] AS [Payment Method]
                    , dt.Active_Status AS [Activation Status]     -- KMH20220228
                    , dt.ActivationOrder AS [Activation OrderNo]
                    , dt.VendorID AS [Vendor ID]
                    , dt.DateActivated AS [Date Activated]          -- NG20230215

                    , oc.[Session ID Invoice Number]

                    , oc.[Session ID Invoice Date]

                    , dt.VZWTier
                    , dt.TFTier
                    , dt.CurrentAssignedAccountID                   --BS20230410
                    , dt.CurrentAssignedAccountName                    --BS20230410
                    , dt.CurrentAssignedAccountAddress1   --NG20240118
                    , dt.CurrentAssignedAccountAddress2 --NG20240118
                    , dt.CurrentAssignedAccountCity --NG20240118
                    , dt.CurrentAssignedAccountState --NG20240118
                    , dt.CurrentAssignedAccountZip --NG20240118
                    , isnull(cm.MACommission, 0) AS [MA Commission] --NG20240118
                    , IIF(atv.ActivationOrder IS NOT NULL, 'Yes', 'NO') AS [IsPortIN] --NG20240118
                FROM #detail AS dt
                JOIN dbo.Account AS ac
                    ON ac.Account_ID = dt.Account_ID
                JOIN dbo.Users AS u
                    ON ac.ParentAccount_SalesRep_UserID = u.User_ID
                JOIN #tempMAIDMap AS tma                                                   -- DJ20210602
                    ON dt.TopMA = tma.TopParentID
                JOIN dbo.Account AS trac
                    ON tma.TracfoneMAID = trac.Account_ID
                LEFT JOIN [Account].[tblAccountUserLink] AS lu
                    ON dt.User_Id = lu.LinkedUserID                                        --BS20230303
                LEFT JOIN dbo.Users AS mau ON mau.User_ID = lu.UserID
                LEFT JOIN tracfone.tblAirtimeMarginTier AS amt                                -- KM20210329
                    ON amt.AccountId = ac.Account_ID AND amt.Enddate >= GETDATE()
                LEFT JOIN tracfone.tblTierCode AS tc                                        -- KM20210329
                    ON tc.TierCode = amt.TierCode AND tc.TierId = amt.TierId
                LEFT JOIN #commission AS cm
                    ON cm.Order_ID = dt.Order_ID
                LEFT JOIN #Acativation AS atv ON atv.ActivationOrder = dt.ActivationOrder
                LEFT JOIN #OrderCommission AS oc
                    ON oc.Orders_ID = dt.Order_ID
                ORDER BY [Order Number];
            END;
        ELSE IF @MPID = 2                      --KMH20220228
            BEGIN
                SELECT
                    ac.Account_ID AS [Merchant ID]
                    , ac.Account_Name AS [Merchant Name]
                    , ac.ParentAccount_Account_ID AS [Parent ID]
                    , u.UserName AS [SalesRep Name]
                    , mau.[User_Id] AS [MA Ordered User Id]                    -- BS20230303
                    , mau.UserName AS [MA Ordered User Name]                    -- BS20230303
                    , tpa.Account_ID AS [Top MA Account ID]
                    , tpa.Account_Name AS [Top MA Account Name]
                    , dt.Order_No AS [Order Number]
                    , dt.TrackingNumber AS [Tracking Number]
                    , dt.BusinessAddress1 AS [Business Address 1] --NG20240118
                    , dt.BusinessAddress2 AS [Business Address 2] --NG20240118
                    , dt.BusinessCity AS [Business City] --NG20240118
                    , dt.BusinessState AS [Business State] --NG20240118
                    , dt.BusinessZipCode AS [Business Zip Code] --NG20240118
                    , dt.SIM AS [SIM]
                    , dt.ESN AS [ESN]
                    , dt.OrderStatus AS [Status]
                    , dt.DateOrdered AS [Date Ordered]
                    , dt.DateFilled AS [Date filled]
                    , dt.Product_ID AS [Product ID]
                    , dt.Name AS [Product Name]
                    , dt.PartNumber AS [Part Number]
                    , dt.DealerCost AS [Dealer Cost]
                    , dt.PRebate AS [Rebate]
                    -- DJJ20220603 -- Rebate based on Activation OrderNo = AuthNumber
                    , dt.[Payment Method] AS [Payment Method]
                    , dt.Active_Status AS [Activation Status]
                    , dt.ActivationOrder AS [Activation OrderNo]
                    , dt.DateActivated AS [Date Activated]

                    , oc.[Session ID Invoice Number]

                    , oc.[Session ID Invoice Date]

                    , dt.VZWTier
                    , dt.TFTier
                    , dt.CurrentAssignedAccountID                   --BS20230410
                    , dt.CurrentAssignedAccountName                    --BS20230410
                    , dt.CurrentAssignedAccountAddress1   --NG20240118
                    , dt.CurrentAssignedAccountAddress2 --NG20240118
                    , dt.CurrentAssignedAccountCity --NG20240118
                    , dt.CurrentAssignedAccountState --NG20240118
                    , dt.CurrentAssignedAccountZip --NG20240118
                    , ISNULL(cm.MACommission, 0) AS [MA Commission] --NG20240118
                    , IIF(atv.ActivationOrder IS NOT NULL, 'Yes', 'NO') AS [IsPortIN] --NG20240118
                FROM #detail AS dt
                JOIN dbo.Account AS ac
                    ON ac.Account_ID = dt.Account_ID
                JOIN dbo.Users AS u
                    ON ac.ParentAccount_SalesRep_UserID = u.User_ID
                JOIN dbo.Account AS tpa
                    ON tpa.Account_ID = dt.TopMA
                LEFT JOIN [Account].[tblAccountUserLink] AS lu                                    --BS20230303
                    ON dt.User_Id = lu.LinkedUserID
                LEFT JOIN dbo.Users AS mau ON mau.User_ID = lu.UserID
                LEFT JOIN #commission AS cm
                    ON cm.Order_ID = dt.Order_ID
                LEFT JOIN #Acativation AS atv ON atv.ActivationOrder = dt.ActivationOrder
                LEFT JOIN #OrderCommission AS oc
                    ON oc.Orders_ID = dt.Order_ID
                ORDER BY [Order Number];
            END;
        ELSE
            BEGIN
                SELECT
                    ac.Account_ID AS [Merchant ID]
                    , ac.Account_Name AS [Merchant Name]
                    , ac.ParentAccount_Account_ID AS [Parent ID]
                    , mau.[User_Id] AS [MA Ordered User Id]    -- BS20230303
                    , mau.UserName AS [MA Ordered User Name]  -- BS20230303
                    , u.UserName AS [SalesRep Name]
                    , tpa.Account_ID AS [Top MA Account ID]
                    , tpa.Account_Name AS [Top MA Account Name]
                    , dt.Order_No AS [Order Number]
                    , dt.TrackingNumber AS [Tracking Number]
                    , dt.BusinessAddress1 AS [Business Address 1] --NG20240118
                    , dt.BusinessAddress2 AS [Business Address 2] --NG20240118
                    , dt.BusinessCity AS [Business City] --NG20240118
                    , dt.BusinessState AS [Business State] --NG20240118
                    , dt.BusinessZipCode AS [Business Zip Code] --NG20240118
                    , dt.SIM AS [SIM]
                    , dt.ESN AS [ESN]
                    , dt.OrderStatus AS [Status]
                    , dt.DateOrdered AS [Date Ordered]
                    , dt.DateFilled AS [Date filled]
                    , dt.Product_ID AS [Product ID]
                    , dt.Name AS [Product Name]
                    , dt.PartNumber AS [Part Number]
                    , dt.DealerCost AS [Dealer Cost]
                    , dt.PRebate AS [Rebate]
                    -- DJJ20220603 -- Rebate based on Activation OrderNo = AuthNumber
                    , dt.[Payment Method] AS [Payment Method]
                    , dt.Active_Status AS [Activation Status]
                    , dt.ActivationOrder AS [Activation OrderNo]
                    , dt.DateActivated AS [Date Activated]

                    , oc.[Session ID Invoice Number]

                    , oc.[Session ID Invoice Date]

                    , dt.VZWTier
                    , dt.TFTier
                    , dt.CurrentAssignedAccountID                   --BS20230410
                    , dt.CurrentAssignedAccountName                    --BS20230410
                    , dt.CurrentAssignedAccountAddress1   --NG20240118
                    , dt.CurrentAssignedAccountAddress2 --NG20240118
                    , dt.CurrentAssignedAccountCity --NG20240118
                    , dt.CurrentAssignedAccountState --NG20240118
                    , dt.CurrentAssignedAccountZip --NG20240118
                    , isnull(cm.MACommission, 0) AS [MA Commission] --NG20240118
                    , IIF(atv.ActivationOrder IS NOT NULL, 'Yes', 'NO') AS [IsPortIN] --NG20240118
                FROM #detail AS dt
                JOIN dbo.Account AS ac
                    ON ac.Account_ID = dt.Account_ID
                JOIN dbo.Users AS u
                    ON ac.ParentAccount_SalesRep_UserID = u.User_ID
                JOIN dbo.Account AS tpa
                    ON tpa.Account_ID = dt.TopMA
                LEFT JOIN [Account].[tblAccountUserLink] AS lu
                    ON dt.User_Id = lu.LinkedUserID
                LEFT JOIN dbo.Users AS mau
                    ON                                                --BS20230303
                        mau.User_ID = lu.UserID
                LEFT JOIN #commission AS cm
                    ON cm.Order_ID = dt.Order_ID
                LEFT JOIN #Acativation AS atv ON atv.ActivationOrder = dt.ActivationOrder
                LEFT JOIN #OrderCommission AS oc
                    ON oc.Orders_ID = dt.Order_ID
                ORDER BY [Order Number];

            END;
    END TRY
    BEGIN CATCH
        SELECT
            error_number() AS ERROR_NO
            , error_message() AS ERROR_MSG;
    END CATCH;
END;
